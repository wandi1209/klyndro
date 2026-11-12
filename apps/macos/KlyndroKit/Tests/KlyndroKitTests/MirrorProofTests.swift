import Foundation
import Testing
@testable import KlyndroKit

private let fixedToken = "9f3a1c5e7b2d4086a1b3c5d7e9f02468"

private actor Recorder {
    var sent: [Envelope] = []
    var reads: [(String, String)] = []
    var deletes: [(String, String)] = []
    func sent(_ e: Envelope) { sent.append(e) }
    func read(_ serial: String, _ path: String) { reads.append((serial, path)) }
    func delete(_ serial: String, _ path: String) { deletes.append((serial, path)) }
}

/// `Result<Void, _>` is not Equatable; compare the failure, or `nil` for success.
private func failure(_ result: Result<Void, MirrorProofError>) -> MirrorProofError? {
    if case .failure(let error) = result { return error }
    return nil
}

private func proof(token: String, ok: Bool = true) -> Envelope {
    Envelope(type: .mirrorProof, body: .object(["token": .string(token), "ok": .bool(ok)]))
}

private func makeVerifier(
    recorder: Recorder,
    connected: Bool = true,
    fileContent: String?,
    timeout: Duration = .seconds(2)
) -> MirrorProofVerifier {
    MirrorProofVerifier(
        send: connected ? { @Sendable envelope in await recorder.sent(envelope) } : nil,
        timeout: timeout,
        makeToken: { @Sendable in fixedToken },
        readFile: { @Sendable serial, path in
            await recorder.read(serial, path)
            return fileContent
        },
        deleteFile: { @Sendable serial, path in await recorder.delete(serial, path) }
    )
}

/// Answers the challenge the way a phone would.
private func answerWhenSent(_ verifier: MirrorProofVerifier, recorder: Recorder, ok: Bool = true, token: String = fixedToken) -> Task<Void, Error> {
    Task {
        for _ in 0..<200 {
            if await !recorder.sent.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await verifier.handleProof(proof(token: token, ok: ok))
    }
}

@Suite("Mirror proof")
struct MirrorProofTests {
    @Test("tokens are 32 lowercase hex characters and unique")
    func tokens() {
        let a = MirrorProof.makeToken()
        let b = MirrorProof.makeToken()
        #expect(MirrorProof.isValidToken(a))
        #expect(a != b)
        for bad in ["", "abc", String(repeating: "g", count: 32), fixedToken.uppercased(), fixedToken + "0"] {
            #expect(!MirrorProof.isValidToken(bad))
        }
    }

    @Test("verify requires an exact match, ignoring surrounding whitespace only")
    func compare() {
        #expect(MirrorProof.verify(expected: fixedToken, fileContent: fixedToken))
        #expect(MirrorProof.verify(expected: fixedToken, fileContent: "\(fixedToken)\n"))
        #expect(!MirrorProof.verify(expected: fixedToken, fileContent: ""))
        #expect(!MirrorProof.verify(expected: fixedToken, fileContent: "x" + fixedToken))
        #expect(!MirrorProof.verify(expected: "short", fileContent: "short"))
    }

    @Test("the device path stays inside the app's own storage")
    func path() {
        #expect(MirrorProof.devicePath(applicationID: "id.my.wandidev.klyndro")
            == "/sdcard/Android/data/id.my.wandidev.klyndro/files/klyndro-mirror-proof")
    }

    @Test("proof decoding rejects bad tokens and a missing ok flag")
    func decoding() {
        #expect(MirrorProof.decodeProof(proof(token: fixedToken))?.ok == true)
        #expect(MirrorProof.decodeProof(proof(token: "nope")) == nil)
        let noOK = Envelope(type: .mirrorProof, body: .object(["token": .string(fixedToken)]))
        #expect(MirrorProof.decodeProof(noOK) == nil)
        #expect(MirrorProof.decodeProof(Envelope(type: .ping, body: nil)) == nil)
    }

    @Test("matching file content proves the device and the session are one phone")
    func success() async {
        let recorder = Recorder()
        let verifier = makeVerifier(recorder: recorder, fileContent: fixedToken)
        let answer = answerWhenSent(verifier, recorder: recorder)
        let result = await verifier.verify(serial: "SERIAL1")
        try? await answer.value

        #expect(failure(result) == nil)
        #expect(await recorder.sent.first?.messageType == .mirrorChallenge)
        #expect(await recorder.reads.first?.0 == "SERIAL1")
        #expect(await recorder.deletes.count == 1)
    }

    @Test("a different phone behind the adb serial is refused")
    func mismatch() async {
        let recorder = Recorder()
        let verifier = makeVerifier(recorder: recorder, fileContent: "0000000000000000000000000000000f")
        let answer = answerWhenSent(verifier, recorder: recorder)
        let result = await verifier.verify(serial: "OTHER")
        try? await answer.value
        #expect(failure(result) == .tokenMismatch)
    }

    @Test("a missing file is refused as unreadable and still cleaned up")
    func unreadable() async {
        let recorder = Recorder()
        let verifier = makeVerifier(recorder: recorder, fileContent: nil)
        let answer = answerWhenSent(verifier, recorder: recorder)
        let result = await verifier.verify(serial: "S")
        try? await answer.value
        #expect(failure(result) == .unreadable)
        #expect(await recorder.deletes.count == 1)
    }

    @Test("no Klyndro session means no mirroring, and adb is never touched")
    func notConnected() async {
        let recorder = Recorder()
        let verifier = makeVerifier(recorder: recorder, connected: false, fileContent: fixedToken)
        #expect(failure(await verifier.verify(serial: "S")) == .notConnected)
        #expect(await recorder.reads.isEmpty)
    }

    @Test("silence from the phone times out")
    func timeout() async {
        let recorder = Recorder()
        let verifier = makeVerifier(recorder: recorder, fileContent: fixedToken, timeout: .milliseconds(150))
        #expect(failure(await verifier.verify(serial: "S")) == .noAnswer)
        #expect(await recorder.reads.isEmpty)
    }

    @Test("a phone that cannot write answers ok false and adb is not read")
    func phoneCannotWrite() async {
        let recorder = Recorder()
        let verifier = makeVerifier(recorder: recorder, fileContent: fixedToken)
        let answer = answerWhenSent(verifier, recorder: recorder, ok: false)
        let result = await verifier.verify(serial: "S")
        try? await answer.value
        #expect(failure(result) == .phoneCouldNotWrite)
        #expect(await recorder.reads.isEmpty)
    }

    @Test("a proof for another token is ignored")
    func wrongToken() async {
        let recorder = Recorder()
        let verifier = makeVerifier(recorder: recorder, fileContent: fixedToken, timeout: .milliseconds(200))
        let answer = answerWhenSent(verifier, recorder: recorder, token: "11111111111111111111111111111111")
        let result = await verifier.verify(serial: "S")
        try? await answer.value
        #expect(failure(result) == .noAnswer)
    }

    @Test("a failed send is reported as no answer")
    func sendFails() async {
        let verifier = MirrorProofVerifier(
            send: { _ in throw MirrorProofError.noAnswer },
            timeout: .seconds(2),
            makeToken: { fixedToken },
            readFile: { _, _ in fixedToken },
            deleteFile: { _, _ in }
        )
        #expect(failure(await verifier.verify(serial: "S")) == .noAnswer)
    }
}
