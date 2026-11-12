import CryptoKit
import Foundation
import Testing
@testable import KlyndroKit

/// Collects what the sender puts on the wire, and can answer the offer like a phone would.
private actor Wire {
    var sent: [Envelope] = []
    var failAfter: Int?

    func record(_ envelope: Envelope) throws {
        if let failAfter, sent.count >= failAfter { throw FileSendError.sendFailed }
        sent.append(envelope)
    }

    func setFailAfter(_ count: Int) { failAfter = count }
    func types() -> [MessageType] { sent.map(\.messageType) }
    func all() -> [Envelope] { sent }
}

private func makeFile(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("klyndro-send-test-\(UUID().uuidString).bin")
    try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
    return url
}

private func answer(_ type: MessageType, for offer: Envelope, reason: String? = nil) -> Envelope {
    var body: [String: JSONValue] = ["transfer_id": offer.body?["transfer_id"] ?? .string("")]
    if let reason { body["reason"] = .string(reason) }
    return Envelope(type: type, body: .object(body))
}

@Suite("File transfer sender")
struct FileTransferSenderTests {
    @Test("sends offer, ordered chunks and a matching complete once the phone accepts")
    func successfulTransfer() async throws {
        let wire = Wire()
        let sender = FileTransferSender { try await wire.record($0) }
        let size = FileMessageCodec.maxChunkRawBytes * 2 + 100
        let url = try makeFile(bytes: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = Task { try await sender.sendFile(at: url) }

        // Wait for the offer, then answer it as the phone would.
        var offer: Envelope?
        for _ in 0..<200 {
            offer = await wire.all().first(where: { $0.messageType == .fileOffer })
            if offer != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sentOffer = try #require(offer)
        await sender.handleAnswer(answer(.fileAccept, for: sentOffer))

        #expect(try await result.value == url.lastPathComponent)

        let envelopes = await wire.all()
        #expect(envelopes.map(\.messageType) == [.fileOffer, .fileChunk, .fileChunk, .fileChunk, .fileComplete])

        let offerBody = try FileMessageCodec.decodeOffer(sentOffer)
        #expect(offerBody.sizeBytes == Int64(size))

        var offsets: [Int] = []
        var rebuilt = Data()
        for chunk in envelopes where chunk.messageType == .fileChunk {
            let offset = try #require(chunk.body?["offset"]?.intValue)
            let encoded = try #require(chunk.body?["data_b64"]?.stringValue)
            let decoded = try #require(Data(base64Encoded: encoded))
            offsets.append(offset)
            rebuilt.append(decoded)
        }
        #expect(offsets == [0, FileMessageCodec.maxChunkRawBytes, FileMessageCodec.maxChunkRawBytes * 2])
        #expect(rebuilt.count == size)

        let digest = SHA256.hash(data: rebuilt).map { String(format: "%02x", $0) }.joined()
        #expect(digest == offerBody.sha256)
        #expect(envelopes.last?.body?["sha256"]?.stringValue == digest)
    }

    @Test("a rejection stops the transfer before any data is sent")
    func rejected() async throws {
        let wire = Wire()
        let sender = FileTransferSender { try await wire.record($0) }
        let url = try makeFile(bytes: 100)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = Task { try await sender.sendFile(at: url) }
        var offer: Envelope?
        for _ in 0..<200 {
            offer = await wire.all().first
            if offer != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await sender.handleAnswer(answer(.fileReject, for: try #require(offer), reason: "too-large"))

        await #expect(throws: FileSendError.rejected("too-large")) { try await result.value }
        #expect(await wire.types() == [.fileOffer])
    }

    @Test("an answer for a different transfer is ignored")
    func wrongTransferAnswerIgnored() async throws {
        let wire = Wire()
        let sender = FileTransferSender { try await wire.record($0) }
        let url = try makeFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = Task { try await sender.sendFile(at: url) }
        var offer: Envelope?
        for _ in 0..<200 {
            offer = await wire.all().first
            if offer != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sentOffer = try #require(offer)

        let stranger = Envelope(
            type: .fileAccept,
            body: .object(["transfer_id": .string("not-this-one")])
        )
        await sender.handleAnswer(stranger)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await wire.types() == [.fileOffer])

        await sender.handleAnswer(answer(.fileAccept, for: sentOffer))
        _ = try await result.value
        #expect(await wire.types().last == .fileComplete)
    }

    @Test("a failed offer send is reported as a send failure")
    func offerSendFails() async throws {
        let wire = Wire()
        await wire.setFailAfter(0)
        let sender = FileTransferSender { try await wire.record($0) }
        let url = try makeFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: FileSendError.sendFailed) { try await sender.sendFile(at: url) }
    }

    @Test("a folder is refused")
    func folderRefused() async throws {
        let sender = FileTransferSender { _ in }
        await #expect(throws: FileSendError.notAFile) {
            try await sender.sendFile(at: FileManager.default.temporaryDirectory)
        }
    }

    @Test("a missing file is refused without sending anything")
    func missingFile() async throws {
        let wire = Wire()
        let sender = FileTransferSender { try await wire.record($0) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID())")
        await #expect(throws: FileSendError.notAFile) { try await sender.sendFile(at: url) }
        #expect(await wire.types().isEmpty)
    }

    @Test("the offer's file name has no path components")
    func offerFilenameSanitized() async throws {
        let wire = Wire()
        let sender = FileTransferSender { try await wire.record($0) }
        let url = try makeFile(bytes: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = Task { try await sender.sendFile(at: url) }
        var offer: Envelope?
        for _ in 0..<200 {
            offer = await wire.all().first
            if offer != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sentOffer = try #require(offer)
        #expect(sentOffer.body?["filename"]?.stringValue?.contains("/") == false)
        await sender.handleAnswer(answer(.fileAccept, for: sentOffer))
        _ = try await result.value
    }
}
