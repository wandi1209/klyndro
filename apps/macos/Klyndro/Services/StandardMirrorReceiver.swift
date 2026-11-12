import AVFoundation
import CoreMedia
import Foundation
import KlyndroKit
import Network
import Observation

/// Receives H.264 Annex-B video packets over a dedicated pinned mutual-TLS 1.3 connection
/// (protocol §5.6) and feeds `CMSampleBuffer`s to an `AVSampleBufferDisplayLayer`.
@MainActor
@Observable
final class StandardMirrorReceiver {
    private(set) var statusText = "Waiting for phone consent…"
    private(set) var isStreaming = false
    let displayLayer = AVSampleBufferDisplayLayer()

    private let pipeline: StreamPipeline

    init(streamID: String, identity: DeviceIdentity, policy: PinPolicy) {
        self.displayLayer.videoGravity = .resizeAspect
        self.pipeline = StreamPipeline(
            streamID: streamID.lowercased(),
            identity: identity,
            policy: policy
        )
        self.pipeline.onStatus = { [weak self] text, streaming in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statusText = text
                self.isStreaming = streaming
            }
        }
        self.pipeline.onSample = { [weak self] sample in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.displayLayer.sampleBufferRenderer.enqueue(sample.value)
                if !self.isStreaming {
                    self.isStreaming = true
                    self.statusText = "Streaming (Standard Mode · No ADB)"
                }
            }
        }
    }

    func start() async throws -> Int {
        try await pipeline.start()
    }

    func stop() {
        pipeline.stop()
        isStreaming = false
        displayLayer.flushAndRemoveImage()
    }
}

private final class StreamPipeline: @unchecked Sendable {
    private let streamID: String
    private let identity: DeviceIdentity
    private let policy: PinPolicy
    private let queue = DispatchQueue(label: "id.my.wandidev.klyndro.stdmirror", qos: .userInitiated)

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var headerVerified = false
    private var headerBuffer = Data()
    private var packetDecoder = VideoStreamPacketDecoder()
    private var formatDescription: CMVideoFormatDescription?
    private var stopped = false

    var onStatus: (@Sendable (String, Bool) -> Void)?
    var onSample: (@Sendable (SendableSampleBuffer) -> Void)?

    init(streamID: String, identity: DeviceIdentity, policy: PinPolicy) {
        self.streamID = streamID
        self.identity = identity
        self.policy = policy
    }

    func start() async throws -> Int {
        let params = TLSConfigurator.parameters(identity: identity, policy: policy, queue: queue)
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = Int(listener.port?.rawValue ?? 0)
                    resumed.runOnce { continuation.resume(returning: port) }
                case .failed(let error):
                    resumed.runOnce { continuation.resume(throwing: error) }
                    self?.onStatus?("Listener failed: \(error)", false)
                case .cancelled:
                    resumed.runOnce { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.activeConnection?.cancel()
            self.activeConnection = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, activeConnection == nil else {
            connection.cancel()
            return
        }
        activeConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStatus?("Connected — waiting for video…", false)
                self.receiveLoop(connection)
            case .failed(let error):
                self.onStatus?("Stream error: \(error)", false)
            case .cancelled:
                self.onStatus?("Stream stopped", false)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.consume(data, on: connection)
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receiveLoop(connection)
        }
    }

    private func consume(_ data: Data, on connection: NWConnection) {
        guard !stopped else { return }
        if !headerVerified {
            headerBuffer.append(data)
            guard headerBuffer.count >= 36 else { return }
            let idData = headerBuffer.prefix(36)
            let receivedID = String(decoding: idData, as: UTF8.self).lowercased()
            guard receivedID == streamID else {
                connection.cancel()
                return
            }
            headerVerified = true
            let remainder = headerBuffer.dropFirst(36)
            headerBuffer.removeAll(keepingCapacity: false)
            if !remainder.isEmpty {
                packetDecoder.append(Data(remainder))
            }
        } else {
            packetDecoder.append(data)
        }

        do {
            while let packet = try packetDecoder.nextPacket() {
                handlePacket(packet)
            }
        } catch {
            connection.cancel()
        }
    }

    private func handlePacket(_ packet: VideoStreamPacket) {
        if let sets = H264AnnexBParser.extractParameterSets(from: packet.payload) {
            updateFormatDescription(sps: sets.sps, pps: sets.pps)
        }
        guard !packet.isConfig, let formatDescription else { return }
        let avcc = H264AnnexBParser.annexBToAVCC(packet.payload)
        guard !avcc.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        let createStatus = avcc.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return -1 }
            var buffer: CMBlockBuffer?
            let allocStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avcc.count,
                flags: 0,
                blockBufferOut: &buffer
            )
            guard allocStatus == noErr, let buffer else { return allocStatus }
            let replaceStatus = CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
            if replaceStatus == noErr { blockBuffer = buffer }
            return replaceStatus
        }
        guard createStatus == noErr, let blockBuffer else { return }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: packet.ptsUs, timescale: 1_000_000),
            decodeTimeStamp: CMTime.invalid
        )
        var size = avcc.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        onSample?(SendableSampleBuffer(value: sampleBuffer))
    }

    private func updateFormatDescription(sps: Data, pps: Data) {
        var newFormat: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                guard let spsPtr = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }
                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormat
                )
            }
        }
        if status == noErr, let newFormat {
            formatDescription = newFormat
        }
    }
}

private struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func runOnce(_ block: () -> Void) {
        let shouldRun = lock.withLock { () -> Bool in
            guard !done else { return false }
            done = true
            return true
        }
        if shouldRun { block() }
    }
}
