import Foundation
import Testing
@testable import KlyndroKit

@Suite("Mirror stream codec")
struct MirrorStreamCodecTests {

    @Test("round trips mirror.stream.start and mirror.stream.stop")
    func roundTripsControlMessages() throws {
        let id = "11111111-2222-4333-8444-555555555555"
        let start = MirrorStreamStartBody(streamID: id, port: 51234, codec: "h264", maxWidth: 1080, fps: 30, bitrate: 4_000_000)
        let decodedStart = try #require(MirrorStreamStartBody.decode(start.toEnvelope()))
        #expect(decodedStart == start)

        let stop = MirrorStreamStopBody(streamID: id, reason: "user_stopped")
        let decodedStop = try #require(MirrorStreamStopBody.decode(stop.toEnvelope()))
        #expect(decodedStop == stop)
    }

    @Test("rejects invalid stream start bounds")
    func rejectsBadStartBounds() {
        let badFields: [String: JSONValue] = [
            "stream_id": .string("11111111-2222-4333-8444-555555555555"),
            "port": .number(0),
            "codec": .string("h264"),
            "max_width": .number(1080),
            "fps": .number(30),
            "bitrate": .number(4_000_000)
        ]
        let badPort = Envelope(type: .mirrorStreamStart, body: .object(badFields))
        #expect(MirrorStreamStartBody.decode(badPort) == nil)
    }

    @Test("encodes and decodes fragmented video stream packets")
    func decodesFragmentedPackets() throws {
        let p1 = VideoStreamPacket(flags: VideoStreamPacket.flagConfig, ptsUs: 0, payload: Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42]))
        let p2 = VideoStreamPacket(flags: VideoStreamPacket.flagKeyFrame, ptsUs: 33_333, payload: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88]))

        var wire = try VideoStreamPacketEncoder.encode(p1)
        wire.append(try VideoStreamPacketEncoder.encode(p2))

        var decoder = VideoStreamPacketDecoder()
        var decoded: [VideoStreamPacket] = []
        for byte in wire {
            decoder.append(Data([byte]))
            if let packet = try decoder.nextPacket() {
                decoded.append(packet)
            }
        }
        #expect(decoded == [p1, p2])
    }

    @Test("splits Annex-B NAL units, extracts SPS/PPS, and converts frames to AVCC")
    func parsesAnnexBAndConvertsToAVCC() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1E])
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])
        let idr = Data([0x65, 0x88, 0x84, 0x21, 0x43])

        var configAnnexB = Data([0x00, 0x00, 0x00, 0x01])
        configAnnexB.append(sps)
        configAnnexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        configAnnexB.append(pps)

        let sets = try #require(H264AnnexBParser.extractParameterSets(from: configAnnexB))
        #expect(sets.sps == sps)
        #expect(sets.pps == pps)

        var frameAnnexB = Data([0x00, 0x00, 0x01])
        frameAnnexB.append(idr)
        let avcc = H264AnnexBParser.annexBToAVCC(frameAnnexB)
        #expect(avcc == Data([0x00, 0x00, 0x00, 0x05]) + idr)
    }
}
