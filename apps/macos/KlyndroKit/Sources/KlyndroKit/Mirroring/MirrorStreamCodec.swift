import Foundation

public struct MirrorStreamStartBody: Equatable, Sendable {
    public static let supportedCodec = "h264"
    public static let widthRange = 240...2160
    public static let fpsRange = 1...60
    public static let bitrateRange = 100_000...20_000_000

    public var streamID: String
    public var port: Int
    public var codec: String
    public var maxWidth: Int
    public var fps: Int
    public var bitrate: Int

    public init(
        streamID: String,
        port: Int,
        codec: String = supportedCodec,
        maxWidth: Int = 1080,
        fps: Int = 30,
        bitrate: Int = 4_000_000
    ) {
        self.streamID = streamID.lowercased()
        self.port = port
        self.codec = codec
        self.maxWidth = maxWidth
        self.fps = fps
        self.bitrate = bitrate
    }

    public func toEnvelope() -> Envelope {
        let fields: [String: JSONValue] = [
            "stream_id": .string(streamID),
            "port": .number(Double(port)),
            "codec": .string(codec),
            "max_width": .number(Double(maxWidth)),
            "fps": .number(Double(fps)),
            "bitrate": .number(Double(bitrate))
        ]
        return Envelope(type: .mirrorStreamStart, body: .object(fields))
    }

    public static func decode(_ envelope: Envelope) -> MirrorStreamStartBody? {
        guard envelope.messageType == .mirrorStreamStart,
              let body = envelope.body,
              let streamID = body["stream_id"]?.stringValue, UUID(uuidString: streamID) != nil,
              let port = body["port"]?.intValue, (1...65535).contains(port),
              let codec = body["codec"]?.stringValue, codec == supportedCodec,
              let maxWidth = body["max_width"]?.intValue, widthRange.contains(maxWidth),
              let fps = body["fps"]?.intValue, fpsRange.contains(fps),
              let bitrate = body["bitrate"]?.intValue, bitrateRange.contains(bitrate) else {
            return nil
        }
        return MirrorStreamStartBody(
            streamID: streamID,
            port: port,
            codec: codec,
            maxWidth: maxWidth,
            fps: fps,
            bitrate: bitrate
        )
    }
}

public struct MirrorStreamStopBody: Equatable, Sendable {
    public var streamID: String
    public var reason: String?

    public init(streamID: String, reason: String? = nil) {
        self.streamID = streamID.lowercased()
        self.reason = reason
    }

    public func toEnvelope() -> Envelope {
        var object: [String: JSONValue] = ["stream_id": .string(streamID)]
        if let reason, !reason.isEmpty {
            object["reason"] = .string(reason)
        }
        return Envelope(type: .mirrorStreamStop, body: .object(object))
    }

    public static func decode(_ envelope: Envelope) -> MirrorStreamStopBody? {
        guard envelope.messageType == .mirrorStreamStop,
              let body = envelope.body,
              let streamID = body["stream_id"]?.stringValue, UUID(uuidString: streamID) != nil else {
            return nil
        }
        let reason = body["reason"]?.stringValue
        return MirrorStreamStopBody(streamID: streamID, reason: reason)
    }
}

public struct VideoStreamPacket: Equatable, Sendable {
    public static let flagConfig: UInt8 = 0x01
    public static let flagKeyFrame: UInt8 = 0x02
    public static let maxPacketLength = 4_194_304 // 4 MiB

    public var flags: UInt8
    public var ptsUs: Int64
    public var payload: Data

    public init(flags: UInt8, ptsUs: Int64, payload: Data) {
        self.flags = flags
        self.ptsUs = ptsUs
        self.payload = payload
    }

    public var isConfig: Bool { (flags & Self.flagConfig) != 0 }
    public var isKeyFrame: Bool { (flags & Self.flagKeyFrame) != 0 }
}

public enum VideoStreamPacketError: Error, Equatable, Sendable {
    case packetTooLarge(Int)
    case invalidPacketLength(Int)
}

public enum VideoStreamPacketEncoder {
    public static func encode(_ packet: VideoStreamPacket) throws -> Data {
        let totalLength = 9 + packet.payload.count
        guard totalLength <= VideoStreamPacket.maxPacketLength else {
            throw VideoStreamPacketError.packetTooLarge(totalLength)
        }
        var data = Data(capacity: 4 + totalLength)
        let len = UInt32(totalLength)
        data.append(UInt8((len >> 24) & 0xFF))
        data.append(UInt8((len >> 16) & 0xFF))
        data.append(UInt8((len >> 8) & 0xFF))
        data.append(UInt8(len & 0xFF))
        data.append(packet.flags)
        let pts = UInt64(bitPattern: packet.ptsUs)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((pts >> shift) & 0xFF))
        }
        data.append(packet.payload)
        return data
    }
}

public struct VideoStreamPacketDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func nextPacket() throws -> VideoStreamPacket? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let totalLength = (Int(buffer[start]) << 24)
            | (Int(buffer[start + 1]) << 16)
            | (Int(buffer[start + 2]) << 8)
            | Int(buffer[start + 3])

        guard totalLength >= 9 else {
            throw VideoStreamPacketError.invalidPacketLength(totalLength)
        }
        guard totalLength <= VideoStreamPacket.maxPacketLength else {
            throw VideoStreamPacketError.packetTooLarge(totalLength)
        }
        guard buffer.count >= 4 + totalLength else { return nil }

        let flags = buffer[start + 4]
        var ptsBits: UInt64 = 0
        for i in 0..<8 {
            ptsBits = (ptsBits << 8) | UInt64(buffer[start + 5 + i])
        }
        let payload = Data(buffer[(start + 13)..<(start + 4 + totalLength)])
        buffer.removeFirst(4 + totalLength)
        return VideoStreamPacket(flags: flags, ptsUs: Int64(bitPattern: ptsBits), payload: payload)
    }
}

/// Splits H.264 Annex-B byte streams (`00 00 01` or `00 00 00 01`) into NAL units and converts
/// non-parameter NAL units into 4-byte big-endian AVCC length-prefixed samples for VideoToolbox.
public enum H264AnnexBParser {
    public struct ParameterSets: Equatable, Sendable {
        public var sps: Data
        public var pps: Data

        public init(sps: Data, pps: Data) {
            self.sps = sps
            self.pps = pps
        }
    }

    public static func splitNALUnits(_ annexB: Data) -> [Data] {
        let bytes = [UInt8](annexB)
        var units: [Data] = []
        var i = 0
        var nalStart: Int?

        while i < bytes.count {
            let startCodeLen: Int?
            if i + 3 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                startCodeLen = 4
            } else if i + 2 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                startCodeLen = 3
            } else {
                startCodeLen = nil
            }

            if let len = startCodeLen {
                if let start = nalStart, i > start {
                    units.append(Data(bytes[start..<i]))
                }
                i += len
                nalStart = i
            } else {
                i += 1
            }
        }
        if let start = nalStart, start < bytes.count {
            units.append(Data(bytes[start..<bytes.count]))
        }
        return units
    }

    public static func extractParameterSets(from annexB: Data) -> ParameterSets? {
        let units = splitNALUnits(annexB)
        var sps: Data?
        var pps: Data?
        for nal in units {
            guard let first = nal.first else { continue }
            let nalType = first & 0x1F
            if nalType == 7 { sps = nal }
            else if nalType == 8 { pps = nal }
        }
        guard let sps, let pps else { return nil }
        return ParameterSets(sps: sps, pps: pps)
    }

    public static func annexBToAVCC(_ annexB: Data) -> Data {
        let units = splitNALUnits(annexB).filter { nal in
            guard let first = nal.first else { return false }
            let nalType = first & 0x1F
            return nalType != 7 && nalType != 8
        }
        var out = Data()
        for nal in units {
            let len = UInt32(nal.count)
            out.append(UInt8((len >> 24) & 0xFF))
            out.append(UInt8((len >> 16) & 0xFF))
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(nal)
        }
        return out
    }
}
