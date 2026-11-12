import CryptoKit
import Foundation

public enum FileSendError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable(String)
    case notAFile
    case tooLarge(Int64)
    case rejected(String)
    case noAnswer
    case sendFailed
    case busy

    public var description: String {
        switch self {
        case .unreadable(let reason): return "The file could not be read: \(reason)"
        case .notAFile: return "Only regular files can be sent, not folders."
        case .tooLarge(let bytes): return "The file is too large to send (\(bytes) bytes)."
        case .rejected(let reason): return "The phone declined the file (\(Self.friendly(reason)))."
        case .noAnswer: return "The phone did not answer. Check that Klyndro is open and connected."
        case .sendFailed: return "The connection dropped while sending."
        case .busy: return "Another file is already being sent."
        }
    }

    private static func friendly(_ reason: String) -> String {
        switch reason {
        case "busy": return "it is receiving another file"
        case "too-large": return "it is too large for the phone"
        case "storage-unavailable": return "no storage available"
        default: return reason
        }
    }
}

/// Streams a local file to the connected phone as `file.offer`, `file.chunk`..., `file.complete`.
///
/// The hash is computed first so the offer can carry it; the file is then read a second time in
/// chunks, never loaded whole into memory. Sending waits for `file.accept` before any data moves.
public actor FileTransferSender {
    public static let maximumFileBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let answerTimeout: Duration = .seconds(15)

    public typealias Send = @Sendable (Envelope) async throws -> Void

    private let send: Send
    private var isSending = false
    private var pendingAnswer: (id: String, continuation: CheckedContinuation<Answer, Never>)?

    public init(send: @escaping Send) {
        self.send = send
    }

    /// Feed `file.accept` and `file.reject` envelopes received from the phone here.
    public func handleAnswer(_ envelope: Envelope) {
        guard let body = envelope.body,
              let id = body["transfer_id"]?.stringValue else { return }
        switch envelope.messageType {
        case .fileAccept:
            resolve(id: id, with: .accepted)
        case .fileReject:
            resolve(id: id, with: .rejected(body["reason"]?.stringValue ?? "rejected"))
        default:
            break
        }
    }

    /// Returns the sent file name. `progress` receives a 0...1 fraction after each chunk.
    public func sendFile(
        at url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> String {
        guard !isSending else { throw FileSendError.busy }
        isSending = true
        defer { isSending = false }

        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw FileSendError.notAFile }
        let size = Int64(values?.fileSize ?? 0)
        guard size <= Self.maximumFileBytes else { throw FileSendError.tooLarge(size) }

        let hash = try Self.sha256(of: url)
        let transferID = UUID().uuidString.lowercased()
        let offer = FileOfferBody(
            transferId: transferID,
            filename: url.lastPathComponent,
            sizeBytes: size,
            sha256: hash,
            mimeType: "application/octet-stream"
        )

        let answer = await waitForAnswer(id: transferID) { [send] in
            try await send(FileMessageCodec.offerEnvelope(offer))
        }
        switch answer {
        case .accepted: break
        case .rejected(let reason): throw FileSendError.rejected(reason)
        case .timedOut: throw FileSendError.noAnswer
        case .sendFailed: throw FileSendError.sendFailed
        }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw FileSendError.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }

        var offset: Int64 = 0
        do {
            while true {
                let data = try handle.read(upToCount: FileMessageCodec.maxChunkRawBytes) ?? Data()
                if data.isEmpty { break }
                let body: [String: JSONValue] = [
                    "transfer_id": .string(transferID),
                    "offset": .number(Double(offset)),
                    "data_b64": .string(data.base64EncodedString())
                ]
                try await send(Envelope(type: .fileChunk, body: .object(body)))
                offset += Int64(data.count)
                progress(size == 0 ? 1 : Double(offset) / Double(size))
            }
            let complete: [String: JSONValue] = [
                "transfer_id": .string(transferID),
                "sha256": .string(hash)
            ]
            try await send(Envelope(type: .fileComplete, body: .object(complete)))
        } catch let error as FileSendError {
            throw error
        } catch {
            throw FileSendError.sendFailed
        }
        return url.lastPathComponent
    }

    // MARK: - Internals

    private enum Answer: Equatable, Sendable {
        case accepted
        case rejected(String)
        case timedOut
        case sendFailed
    }

    /// Sends the offer and suspends until the phone answers, the send fails, or the timeout fires.
    /// Exactly one of those resolves the continuation: `resolve` clears `pendingAnswer` first, so a
    /// late second event finds nothing to resume.
    private func waitForAnswer(id: String, sendOffer: @escaping @Sendable () async throws -> Void) async -> Answer {
        let timeout = Task { [weak self] in
            try await Task.sleep(for: Self.answerTimeout)
            await self?.resolve(id: id, with: .timedOut)
        }
        defer { timeout.cancel() }

        return await withCheckedContinuation { continuation in
            pendingAnswer = (id, continuation)
            Task { [weak self] in
                do {
                    try await sendOffer()
                } catch {
                    await self?.resolve(id: id, with: .sendFailed)
                }
            }
        }
    }

    private func resolve(id: String, with answer: Answer) {
        guard let pending = pendingAnswer, pending.id == id else { return }
        pendingAnswer = nil
        pending.continuation.resume(returning: answer)
    }

    static func sha256(of url: URL) throws -> String {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw FileSendError.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
