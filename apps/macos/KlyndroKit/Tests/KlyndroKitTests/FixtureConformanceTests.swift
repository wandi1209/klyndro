import Foundation
import KlyndroKit
import Testing

/// Decoder conformance against the shared fixtures in `protocol/fixtures`, which the
/// Android test suite reads as well. If these two suites disagree, the protocol has
/// silently forked.
@Suite("Protocol fixture conformance")
struct FixtureConformanceTests {
    struct Manifest: Decodable {
        struct Entry: Decodable {
            let file: String
            let expect: String
            let type: String?
        }
        let protocolVersion: Int
        let fixtures: [Entry]

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version"
            case fixtures
        }
    }

    static var fixturesDirectory: URL {
        // .../apps/macos/KlyndroKit/Tests/KlyndroKitTests/FixtureConformanceTests.swift
        var url = URL(filePath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appending(path: "protocol/fixtures", directoryHint: .isDirectory)
    }

    static func loadManifest() throws -> Manifest {
        let data = try Data(contentsOf: fixturesDirectory.appending(path: "manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    @Test("manifest agrees with the fixture directory")
    func manifestMatchesDirectory() throws {
        let manifest = try Self.loadManifest()
        #expect(manifest.protocolVersion == Envelope.currentVersion)

        let onDisk = try FileManager.default
            .contentsOfDirectory(atPath: Self.fixturesDirectory.path)
            .filter { $0.hasSuffix(".json") && $0 != "manifest.json" }
            .sorted()
        let declared = manifest.fixtures.map(\.file).sorted()

        #expect(onDisk == declared)
    }

    @Test("every fixture produces the declared decoder outcome")
    func fixturesDecodeAsDeclared() throws {
        let manifest = try Self.loadManifest()
        #expect(!manifest.fixtures.isEmpty)

        for entry in manifest.fixtures {
            let url = Self.fixturesDirectory.appending(path: entry.file)
            let payload = try Data(contentsOf: url)

            switch entry.expect {
            case "valid":
                let envelope = try EnvelopeCodec.decode(payload: payload)
                #expect(envelope.type == entry.type, "\(entry.file): type mismatch")
                #expect(envelope.messageType.isKnown, "\(entry.file): expected a known type")
                #expect(envelope.messageType.wireName == entry.type)
            case "unknown_type":
                let envelope = try EnvelopeCodec.decode(payload: payload)
                #expect(envelope.type == entry.type, "\(entry.file): type mismatch")
                #expect(!envelope.messageType.isKnown, "\(entry.file): expected an unknown type")
            case "malformed":
                #expect(throws: ProtocolError.self, "\(entry.file): expected a rejection") {
                    _ = try EnvelopeCodec.decode(payload: payload)
                }
            default:
                Issue.record("Unknown expectation '\(entry.expect)' in manifest for \(entry.file)")
            }
        }
    }

    @Test("re-encoding a fixture preserves its meaning")
    func reEncodePreservesMeaning() throws {
        let manifest = try Self.loadManifest()
        let validFixtures = manifest.fixtures.filter { $0.expect != "malformed" }

        for entry in validFixtures {
            let payload = try Data(
                contentsOf: Self.fixturesDirectory.appending(path: entry.file)
            )
            let original = try EnvelopeCodec.decode(payload: payload)
            let reEncoded = try EnvelopeCodec.encode(original)
            let roundTripped = try EnvelopeCodec.decode(payload: reEncoded)
            #expect(roundTripped == original, "\(entry.file): round trip changed the envelope")
        }
    }
}
