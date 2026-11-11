import Foundation
import SwiftASN1
import X509

/// Builds the device's self-signed identity certificate.
///
/// The encoding is delegated to Apple's `X509` package; the signature is produced by the
/// caller's `Certificate.PrivateKey`, which wraps a Security.framework key. No cryptographic
/// primitive is implemented here (see ADR 0008).
enum SelfSignedCertificate {
    static let subjectCommonNamePrefix = "Klyndro "

    /// Creates a self-signed certificate and returns its DER encoding.
    ///
    /// - Parameters:
    ///   - privateKey: key that will sign the certificate and be its subject public key.
    ///   - commonName: display name of the device, embedded for diagnostics only.
    ///   - validity: lifetime. Ten years, because re-pairing is the only cost of expiry.
    static func makeDER(
        privateKey: Certificate.PrivateKey,
        commonName: String,
        notBefore: Date = Date().addingTimeInterval(-3600),
        validity: TimeInterval = 60 * 60 * 24 * 3650
    ) throws -> Data {
        let publicKey = privateKey.publicKey

        let name = try DistinguishedName {
            CommonName(subjectCommonNamePrefix + commonName)
        }

        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: notBefore,
            notValidAfter: notBefore.addingTimeInterval(validity),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                // A leaf that is not a CA. Critical so a peer that validates chains rejects
                // it on its own terms; Klyndro pins fingerprints instead of chaining.
                Critical(BasicConstraints.notCertificateAuthority)
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
                SubjectKeyIdentifier(keyIdentifier: publicKey.subjectPublicKeyInfoBytes)
            },
            issuerPrivateKey: privateKey
        )

        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return Data(serializer.serializedBytes)
    }
}
