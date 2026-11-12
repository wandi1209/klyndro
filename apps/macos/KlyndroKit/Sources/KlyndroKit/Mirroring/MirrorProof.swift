import Foundation
import Security

public enum MirrorProofError: Error, Equatable, Sendable, CustomStringConvertible {
    case notConnected
    case noAnswer
    case phoneCouldNotWrite
    case tokenMismatch
    case unreadable

    public var description: String {
        switch self {
        case .notConnected:
            return "Connect the phone to Klyndro first. Mirroring only works with a phone paired in Klyndro."
        case .noAnswer:
            return "The phone did not answer. Open Klyndro on the phone and check that it is connected."
        case .phoneCouldNotWrite:
            return "The phone could not prepare the check. Update Klyndro on the phone and try again."
        case .tokenMismatch:
            return "This adb device is not the phone paired with Klyndro, so mirroring was refused."
        case .unreadable:
            return "Could not confirm which phone this adb device is. Check that it is authorised for adb."
        }
    }
}

/// Binds an adb device to the phone that is authenticated over the Klyndro session (protocol §5.4a).
///
/// The Mac sends a fresh random token; the phone writes it into its own app storage; the Mac reads
/// it back through the adb serial it wants to mirror. Equal content means both channels reach the
/// same phone. Pure parts (token rules, comparison) are separated so they can be tested alone.
public enum MirrorProof {
    public static let fileName = "klyndro-mirror-proof"
    public static let tokenLength = 32

    /// 16 random bytes as lowercase hex.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "system random source failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func isValidToken(_ token: String) -> Bool {
        token.count == tokenLength && token.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Where the phone writes the token, as seen over adb.
    public static func devicePath(applicationID: String) -> String {
        "/sdcard/Android/data/\(applicationID)/files/\(fileName)"
    }

    public static func challengeEnvelope(token: String) -> Envelope {
        Envelope(type: .mirrorChallenge, body: .object(["token": .string(token)]))
    }

    public struct Proof: Equatable, Sendable {
        public var token: String
        public var ok: Bool
    }

    public static func decodeProof(_ envelope: Envelope) -> Proof? {
        guard envelope.messageType == .mirrorProof,
              let body = envelope.body,
              let token = body["token"]?.stringValue, isValidToken(token) else { return nil }
        let ok: Bool
        if case .bool(let value)? = body["ok"] { ok = value } else { return nil }
        return Proof(token: token, ok: ok)
    }

    /// Compares what the phone wrote with what was asked. Whitespace around the file is ignored.
    public static func verify(expected: String, fileContent: String) -> Bool {
        let trimmed = fileContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidToken(expected) && trimmed == expected
    }
}

/// Runs the challenge against a connected phone and reads the proof back through adb.
///
/// Every collaborator is injected, so the sequence (send, wait, read, compare, clean up) is tested
/// without a phone: `send` puts an envelope on the Klyndro session, `readFile` runs
/// `adb -s <serial> shell cat <path>`, and `deleteFile` removes the token afterwards.
public actor MirrorProofVerifier {
    public static let answerTimeout: Duration = .seconds(10)

    public typealias Send = @Sendable (Envelope) async throws -> Void
    public typealias ReadFile = @Sendable (_ serial: String, _ path: String) async -> String?
    public typealias DeleteFile = @Sendable (_ serial: String, _ path: String) async -> Void

    private let send: Send?
    private let readFile: ReadFile
    private let deleteFile: DeleteFile
    private let applicationID: String
    private let makeToken: @Sendable () -> String
    private let timeout: Duration
    private var pending: (token: String, continuation: CheckedContinuation<MirrorProof.Proof?, Never>)?

    /// `send` is nil when no Klyndro session is connected.
    public init(
        send: Send?,
        applicationID: String = "id.my.wandidev.klyndro",
        timeout: Duration = MirrorProofVerifier.answerTimeout,
        makeToken: @escaping @Sendable () -> String = { MirrorProof.makeToken() },
        readFile: @escaping ReadFile,
        deleteFile: @escaping DeleteFile
    ) {
        self.send = send
        self.applicationID = applicationID
        self.timeout = timeout
        self.makeToken = makeToken
        self.readFile = readFile
        self.deleteFile = deleteFile
    }

    /// Feed `mirror.proof` envelopes received from the phone here.
    public func handleProof(_ envelope: Envelope) {
        guard let proof = MirrorProof.decodeProof(envelope),
              let current = pending, current.token == proof.token else { return }
        pending = nil
        current.continuation.resume(returning: proof)
    }

    /// Succeeds only when the adb device `serial` is the phone on the Klyndro session.
    public func verify(serial: String) async -> Result<Void, MirrorProofError> {
        guard let send else { return .failure(.notConnected) }
        let token = makeToken()
        let path = MirrorProof.devicePath(applicationID: applicationID)

        let proof: MirrorProof.Proof? = await withCheckedContinuation { continuation in
            pending = (token, continuation)
            Task { [timeout, weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(token: token)
            }
            Task { [weak self] in
                do { try await send(MirrorProof.challengeEnvelope(token: token)) } catch {
                    await self?.expire(token: token)
                }
            }
        }

        guard let proof else { return .failure(.noAnswer) }
        guard proof.ok else { return .failure(.phoneCouldNotWrite) }

        let content = await readFile(serial, path)
        await deleteFile(serial, path)
        guard let content else { return .failure(.unreadable) }
        return MirrorProof.verify(expected: token, fileContent: content)
            ? .success(())
            : .failure(.tokenMismatch)
    }

    private func expire(token: String) {
        guard let current = pending, current.token == token else { return }
        pending = nil
        current.continuation.resume(returning: nil)
    }
}
