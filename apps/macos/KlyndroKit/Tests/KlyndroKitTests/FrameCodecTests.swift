import Foundation
import KlyndroKit
import Testing

@Suite("Frame codec")
struct FrameCodecTests {
    private let sample = Frame(
        kind: .envelope,
        payload: Data(#"{"v":1,"id":"3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22","type":"ping","ts":1}"#.utf8)
    )

    @Test("round trips a single frame")
    func roundTrip() throws {
        let encoded = try FrameEncoder.encode(sample)
        var decoder = FrameDecoder()
        decoder.append(encoded)
        #expect(try decoder.nextFrame() == sample)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("length prefix is big endian and includes the kind byte")
    func lengthPrefix() throws {
        let encoded = try FrameEncoder.encode(sample)
        let declared = (Int(encoded[0]) << 24) | (Int(encoded[1]) << 16)
            | (Int(encoded[2]) << 8) | Int(encoded[3])
        #expect(declared == sample.payload.count + 1)
        #expect(encoded[4] == FrameKind.envelope.rawValue)
    }

    @Test("reassembles a frame delivered one byte at a time")
    func byteAtATime() throws {
        let encoded = try FrameEncoder.encode(sample)
        var decoder = FrameDecoder()

        for byte in encoded.dropLast() {
            decoder.append(Data([byte]))
            #expect(try decoder.nextFrame() == nil)
        }
        decoder.append(Data([encoded.last!]))
        #expect(try decoder.nextFrame() == sample)
    }

    @Test("decodes several frames from one buffer")
    func coalescedFrames() throws {
        let other = Frame(kind: .envelope, payload: Data("{}".utf8))
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(sample) + FrameEncoder.encode(other))

        #expect(try decoder.nextFrame() == sample)
        #expect(try decoder.nextFrame() == other)
        #expect(try decoder.nextFrame() == nil)
    }

    @Test("rejects a length above the wire limit without buffering the payload")
    func rejectsOversizedLength() throws {
        var decoder = FrameDecoder()
        let oversized = UInt32(FramingLimits.maxFrameBytes + 1)
        decoder.append(Data([
            UInt8((oversized >> 24) & 0xFF),
            UInt8((oversized >> 16) & 0xFF),
            UInt8((oversized >> 8) & 0xFF),
            UInt8(oversized & 0xFF),
            FrameKind.envelope.rawValue
        ]))

        #expect(throws: ProtocolError.frameTooLarge(FramingLimits.maxFrameBytes + 1)) {
            _ = try decoder.nextFrame()
        }
    }

    @Test("rejects a zero length")
    func rejectsZeroLength() {
        var decoder = FrameDecoder()
        decoder.append(Data([0, 0, 0, 0]))
        #expect(throws: ProtocolError.emptyFrame) {
            _ = try decoder.nextFrame()
        }
    }

    @Test("rejects an unknown frame kind")
    func rejectsUnknownKind() {
        var decoder = FrameDecoder()
        decoder.append(Data([0, 0, 0, 2, 0x7F, 0x00]))
        #expect(throws: ProtocolError.unsupportedFrameKind(0x7F)) {
            _ = try decoder.nextFrame()
        }
    }

    @Test("encoder refuses to produce an oversized frame")
    func encoderEnforcesLimit() {
        let payload = Data(repeating: 0x41, count: FramingLimits.maxFrameBytes)
        #expect(throws: ProtocolError.frameTooLarge(FramingLimits.maxFrameBytes + 1)) {
            _ = try FrameEncoder.encode(Frame(kind: .envelope, payload: payload))
        }
    }

    @Test("accepts a payload exactly at the limit")
    func acceptsMaximumPayload() throws {
        let payload = Data(repeating: 0x41, count: FramingLimits.maxPayloadBytes)
        let encoded = try FrameEncoder.encode(Frame(kind: .envelope, payload: payload))
        var decoder = FrameDecoder()
        decoder.append(encoded)
        #expect(try decoder.nextFrame()?.payload.count == FramingLimits.maxPayloadBytes)
    }
}
