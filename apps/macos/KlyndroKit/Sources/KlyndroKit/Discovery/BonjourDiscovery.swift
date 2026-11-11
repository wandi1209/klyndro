import Foundation
import Network

/// DNS TXT record encoding for Klyndro advertisements (protocol §8).
///
/// Network.framework takes raw TXT data on publish, so the `key=value` encoding is explicit
/// rather than implied. Each entry is one length byte followed by that many ASCII bytes.
public enum TXTRecord {
    public static let maximumEntryBytes = 255

    public static func encode(_ fields: [String: String]) -> Data {
        var data = Data()
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            let entry = Array("\(key)=\(value)".utf8)
            let bounded = entry.prefix(maximumEntryBytes)
            data.append(UInt8(bounded.count))
            data.append(contentsOf: bounded)
        }
        return data
    }

    public static func decode(_ data: Data) -> [String: String] {
        var fields: [String: String] = [:]
        var index = data.startIndex

        while index < data.endIndex {
            let length = Int(data[index])
            index = data.index(after: index)
            guard length > 0, data.distance(from: index, to: data.endIndex) >= length else { break }
            let end = data.index(index, offsetBy: length)
            let entry = String(decoding: data[index..<end], as: UTF8.self)
            index = end

            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[entry.startIndex..<separator])
            let value = String(entry[entry.index(after: separator)...])
            if !key.isEmpty {
                fields[key] = value
            }
        }
        return fields
    }
}

/// A device seen through Bonjour, before any trust decision.
public struct DiscoveredPeer: Sendable, Equatable, Identifiable {
    public var deviceID: DeviceID
    public var name: String
    public var fingerprint: Fingerprint
    public var capabilities: [Capability]
    public var serviceName: String
    public var isPaired: Bool

    public var id: String { deviceID.hex }

    public init(
        deviceID: DeviceID,
        name: String,
        fingerprint: Fingerprint,
        capabilities: [Capability],
        serviceName: String,
        isPaired: Bool
    ) {
        self.deviceID = deviceID
        self.name = name
        self.fingerprint = fingerprint
        self.capabilities = capabilities
        self.serviceName = serviceName
        self.isPaired = isPaired
    }

    public static let serviceType = "_klyndro._tcp"

    /// Parses a TXT record. Returns `nil` when a mandatory field is missing or malformed:
    /// an unusable advertisement is skipped rather than shown as a broken device.
    public static func parse(
        serviceName: String,
        fields: [String: String],
        trustedPeers: [TrustedPeer] = []
    ) -> DiscoveredPeer? {
        guard let idHex = fields["id"], let deviceID = DeviceID(hex: idHex),
              let name = fields["name"], !name.isEmpty,
              let fingerprintHex = fields["fp"], let fingerprint = Fingerprint(hex: fingerprintHex),
              fields["proto"] == String(Envelope.currentVersion) else {
            return nil
        }

        let capabilities = Capability.parse(
            fields["caps"]?.split(separator: ",").map(String.init) ?? []
        )
        let isPaired = trustedPeers.contains { $0.deviceID == deviceID.hex }

        return DiscoveredPeer(
            deviceID: deviceID,
            name: String(name.prefix(HandshakeCodec.maximumDeviceNameBytes)),
            fingerprint: fingerprint,
            capabilities: capabilities,
            serviceName: serviceName,
            isPaired: isPaired
        )
    }

    /// TXT fields this device publishes for itself.
    static func localIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(firstAddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback else { continue }

            let addr = ptr.pointee.ifa_addr.pointee
            if addr.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var sa = ptr.pointee.ifa_addr.pointee
                if getnameinfo(&sa, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let str = String(cString: hostname)
                    if !str.isEmpty && !str.hasPrefix("127.") {
                        return str
                    }
                }
            }
        }
        return nil
    }

    public static func advertisementFields(
        deviceID: DeviceID,
        name: String,
        fingerprint: Fingerprint,
        capabilities: [Capability]
    ) -> [String: String] {
        var fields: [String: String] = [
            "id": deviceID.hex,
            "name": String(name.prefix(HandshakeCodec.maximumDeviceNameBytes)),
            "proto": String(Envelope.currentVersion),
            "fp": fingerprint.hex,
            "caps": capabilities.map(\.rawValue).joined(separator: ",")
        ]
        if let ipv4 = localIPv4Address() {
            fields["ipv4"] = ipv4
        }
        return fields
    }
}

/// Publishes this device and browses for peers over Bonjour.
///
/// Advertising carries no trust: the fingerprint in TXT is a *hint* used to recognise known
/// devices before connecting. Trust still comes from the TLS handshake and the pin.
public final class BonjourDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "id.my.wandidev.klyndro.discovery")
    private let trustedPeers: @Sendable () -> [TrustedPeer]
    private var browser: NWBrowser?
    private var continuation: AsyncStream<[DiscoveredPeer]>.Continuation?
    private var peersByService: [String: DiscoveredPeer] = [:]
    private let lock = NSLock()

    public init(trustedPeers: @escaping @Sendable () -> [TrustedPeer]) {
        self.trustedPeers = trustedPeers
    }

    public static func service(
        deviceID: DeviceID,
        name: String,
        fingerprint: Fingerprint,
        capabilities: [Capability]
    ) -> NWListener.Service {
        let fields = DiscoveredPeer.advertisementFields(
            deviceID: deviceID,
            name: name,
            fingerprint: fingerprint,
            capabilities: capabilities
        )
        return NWListener.Service(
            name: "\(name) [\(deviceID.hex.suffix(6))]",
            type: DiscoveredPeer.serviceType,
            domain: nil,
            txtRecord: TXTRecord.encode(fields)
        )
    }

    /// Starts browsing. The stream emits the full current set on every change.
    public func browse() -> AsyncStream<[DiscoveredPeer]> {
        let (stream, continuation) = AsyncStream<[DiscoveredPeer]>.makeStream()
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: DiscoveredPeer.serviceType, domain: nil),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.publishSnapshot()
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.handle(results)
        }

        browser.start(queue: queue)
        lock.lock()
        self.browser = browser
        lock.unlock()

        return stream
    }

    public func stopBrowsing() {
        lock.lock()
        let browser = self.browser
        self.browser = nil
        let continuation = self.continuation
        self.continuation = nil
        peersByService.removeAll()
        lock.unlock()

        browser?.cancel()
        continuation?.finish()
    }

    // MARK: - Internals

    private func handle(_ results: Set<NWBrowser.Result>) {
        var updated: [String: DiscoveredPeer] = [:]

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            guard case .bonjour(let txt) = result.metadata else { continue }

            let fields = txt.dictionary
            if let peer = DiscoveredPeer.parse(
                serviceName: name,
                fields: fields,
                trustedPeers: trustedPeers()
            ) {
                updated[name] = peer
            }
        }

        lock.lock()
        peersByService = updated
        lock.unlock()
        publishSnapshot()
    }

    private func publishSnapshot() {
        lock.lock()
        let snapshot = peersByService.values.sorted { $0.name < $1.name }
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(snapshot)
    }
}
