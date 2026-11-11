import Foundation
import Security
import SwiftASN1
import X509

/// A device's long-term identity: a P-256 key in the Keychain, its self-signed certificate,
/// and the pinned fingerprint derived from the public key.
public struct DeviceIdentity: @unchecked Sendable {
    /// Usable directly for `sec_protocol_options_set_local_identity`.
    public let identity: SecIdentity
    public let certificate: SecCertificate
    /// SHA-256 of the certificate's SubjectPublicKeyInfo, lowercase hex.
    public let fingerprint: Fingerprint
    public let commonName: String

    public var certificateDER: Data {
        SecCertificateCopyData(certificate) as Data
    }
}

public enum IdentityError: Error, CustomStringConvertible {
    case keyGenerationFailed(String)
    case certificateEncodingFailed(String)
    case certificateRejected
    case keychainFailure(operation: String, status: OSStatus)
    case identityUnavailable

    public var description: String {
        switch self {
        case .keyGenerationFailed(let reason):
            return "key generation failed: \(reason)"
        case .certificateEncodingFailed(let reason):
            return "certificate encoding failed: \(reason)"
        case .certificateRejected:
            return "the system rejected the generated certificate"
        case .keychainFailure(let operation, let status):
            return "keychain \(operation) failed (status \(status))"
        case .identityUnavailable:
            return "key and certificate could not be joined into an identity"
        }
    }
}

/// Creates and loads the device identity from the login Keychain.
///
/// Storage layout, learned empirically (see ADR 0008):
/// - The private key is a permanent Keychain key tagged with `applicationTag`.
/// - The certificate is added as a Keychain certificate item so the system can join it with
///   the key via `SecIdentityCreateWithCertificate`.
/// - The certificate **DER** is also stored as a generic-password item, because `SecItemAdd`
///   for a certificate silently ignores `kSecAttrLabel` on macOS 27, so a certificate cannot
///   be found again by label. Reading the DER and rebuilding the `SecCertificate` is reliable.
///
/// The data-protection keychain is not used: `kSecUseDataProtectionKeychain` fails with
/// `errSecMissingEntitlement` (-34018) for an app without a keychain access group.
public enum DeviceIdentityStore {
    /// Application tag / account identifier for the key and the stored certificate.
    public static let defaultTag = "id.my.wandidev.klyndro.identity"
    /// Service name for the certificate-DER item.
    public static let certificateService = "id.my.wandidev.klyndro.identity.certificate"

    /// Loads the existing identity, or creates one on first run.
    public static func loadOrCreate(
        commonName: String,
        tag: String = defaultTag
    ) throws -> DeviceIdentity {
        if let existing = try load(tag: tag) {
            return existing
        }
        return try create(commonName: commonName, tag: tag)
    }

    /// Returns the stored identity, or `nil` when this device has never created one.
    public static func load(tag: String = defaultTag) throws -> DeviceIdentity? {
        guard let der = try storedCertificateDER(tag: tag) else { return nil }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw IdentityError.certificateRejected
        }
        return try makeIdentity(certificate: certificate, tag: tag)
    }

    /// Generates and stores a brand new identity, replacing any existing one.
    public static func create(commonName: String, tag: String = defaultTag) throws -> DeviceIdentity {
        try delete(tag: tag)

        let key = try generateKey(tag: tag)
        let privateKey: Certificate.PrivateKey
        do {
            privateKey = try Certificate.PrivateKey(key)
        } catch {
            throw IdentityError.certificateEncodingFailed(String(describing: error))
        }

        let der: Data
        do {
            der = try SelfSignedCertificate.makeDER(privateKey: privateKey, commonName: commonName)
        } catch {
            throw IdentityError.certificateEncodingFailed(String(describing: error))
        }

        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw IdentityError.certificateRejected
        }

        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw IdentityError.keychainFailure(operation: "add certificate", status: addStatus)
        }

        let storeStatus = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: certificateService,
            kSecAttrAccount as String: tag,
            kSecValueData as String: der
        ] as CFDictionary, nil)
        guard storeStatus == errSecSuccess else {
            throw IdentityError.keychainFailure(operation: "store certificate", status: storeStatus)
        }

        return try makeIdentity(certificate: certificate, tag: tag)
    }

    /// Removes the key, certificate, and stored DER. Used by tests and by "reset identity".
    public static func delete(tag: String = defaultTag) throws {
        if let der = try? storedCertificateDER(tag: tag),
           let certificate = SecCertificateCreateWithData(nil, der as CFData) {
            // Certificates cannot be found by label, but they can be deleted by reference.
            SecItemDelete([
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate
            ] as CFDictionary)
        }

        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: certificateService,
            kSecAttrAccount as String: tag
        ] as CFDictionary)

        let keyStatus = SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8)
        ] as CFDictionary)
        guard keyStatus == errSecSuccess || keyStatus == errSecItemNotFound else {
            throw IdentityError.keychainFailure(operation: "delete key", status: keyStatus)
        }
    }

    // MARK: - Ephemeral certificates (tests, previews)

    /// A certificate built without touching the Keychain.
    ///
    /// It is not a device identity: there is no persisted key behind it. Used where only the
    /// DER bytes and the pinned fingerprint matter.
    public struct EphemeralCertificate: Sendable {
        public let der: Data
        public let fingerprint: Fingerprint
    }

    public static func makeEphemeralCertificate(commonName: String) throws -> EphemeralCertificate {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256
        ] as CFDictionary, &error) else {
            let reason = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
            throw IdentityError.keyGenerationFailed(reason)
        }

        let privateKey: Certificate.PrivateKey
        do {
            privateKey = try Certificate.PrivateKey(key)
        } catch {
            throw IdentityError.certificateEncodingFailed(String(describing: error))
        }

        let der: Data
        do {
            der = try SelfSignedCertificate.makeDER(privateKey: privateKey, commonName: commonName)
        } catch {
            throw IdentityError.certificateEncodingFailed(String(describing: error))
        }

        return EphemeralCertificate(
            der: der,
            fingerprint: try fingerprint(ofCertificateDER: der)
        )
    }

    // MARK: - Internals

    private static func storedCertificateDER(tag: String) throws -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: certificateService,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw IdentityError.keychainFailure(operation: "read certificate", status: status)
        }
    }

    private static func generateKey(tag: String) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(tag.utf8),
                kSecAttrLabel as String: tag
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let reason = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
            throw IdentityError.keyGenerationFailed(reason)
        }
        return key
    }

    private static func makeIdentity(
        certificate: SecCertificate,
        tag: String
    ) throws -> DeviceIdentity {
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw IdentityError.identityUnavailable
        }

        return DeviceIdentity(
            identity: identity,
            certificate: certificate,
            fingerprint: try fingerprint(of: certificate),
            commonName: commonName(of: certificate) ?? tag
        )
    }

    /// Hash of the SubjectPublicKeyInfo, parsed from the stored certificate.
    public static func fingerprint(of certificate: SecCertificate) throws -> Fingerprint {
        try fingerprint(ofCertificateDER: SecCertificateCopyData(certificate) as Data)
    }

    public static func fingerprint(ofCertificateDER der: Data) throws -> Fingerprint {
        let parsed: Certificate
        do {
            parsed = try Certificate(derEncoded: Array(der))
        } catch {
            throw IdentityError.certificateEncodingFailed(String(describing: error))
        }
        return try Fingerprint(spki: subjectPublicKeyInfo(of: parsed))
    }

    /// Full DER `SubjectPublicKeyInfo` (91 bytes for a P-256 key), not the bare key point.
    ///
    /// This is the representation the TLS layer reports via
    /// `sec_protocol_metadata_copy_peer_public_key`, and the one the protocol pins. Hashing the
    /// bare point here would make local and remote fingerprints disagree.
    static func subjectPublicKeyInfo(of certificate: Certificate) throws -> Data {
        var serializer = DER.Serializer()
        do {
            try certificate.publicKey.serialize(
                into: &serializer,
                withIdentifier: Certificate.PublicKey.defaultIdentifier
            )
        } catch {
            throw IdentityError.certificateEncodingFailed(String(describing: error))
        }
        return Data(serializer.serializedBytes)
    }

    private static func commonName(of certificate: SecCertificate) -> String? {
        guard let parsed = try? Certificate(derEncoded: Array(SecCertificateCopyData(certificate) as Data))
        else { return nil }
        for relativeName in parsed.subject {
            for attribute in relativeName where attribute.type == .NameAttributes.commonName {
                return String(attribute.value)
            }
        }
        return nil
    }
}
