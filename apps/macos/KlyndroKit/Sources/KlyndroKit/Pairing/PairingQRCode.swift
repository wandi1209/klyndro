import Darwin
import Foundation

/// Encodes and decodes Klyndro pairing QR payloads (`klyndro://pair?v=1&host=...&port=...&fp=...`).
///
/// Scanning the QR gives the phone both the Mac's current LAN address and its pinned SPKI
/// fingerprint before the TLS pairing handshake starts; the six-digit SAS comparison still runs.
public struct PairingQRPayload: Equatable, Sendable {
    public static let currentVersion = 1

    public var host: String
    public var port: Int
    public var fingerprint: Fingerprint
    public var name: String?

    public init(host: String, port: Int, fingerprint: Fingerprint, name: String? = nil) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public func encodeURI() -> String? {
        guard Self.isValidHost(host), (1...65535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "klyndro"
        components.host = "pair"
        var items = [
            URLQueryItem(name: "v", value: String(Self.currentVersion)),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "fp", value: fingerprint.hex)
        ]
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            items.append(URLQueryItem(name: "name", value: String(trimmed.prefix(64))))
        }
        components.queryItems = items
        return components.string
    }

    public static func parse(_ raw: String) -> PairingQRPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "klyndro",
              components.host?.lowercased() == "pair",
              let items = components.queryItems else {
            return nil
        }

        let query = Dictionary(items.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        }, uniquingKeysWith: { _, latest in latest })

        guard query["v"] == String(currentVersion),
              let host = query["host"], isValidHost(host),
              let portText = query["port"], let port = Int(portText), (1...65535).contains(port),
              let fpText = query["fp"], let fingerprint = Fingerprint(hex: fpText) else {
            return nil
        }

        let name = query["name"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            .map { String($0.prefix(64)) }

        return PairingQRPayload(host: host, port: port, fingerprint: fingerprint, name: name)
    }

    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        guard !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" }) else { return false }
        return !host.hasPrefix(".") && !host.hasSuffix(".") && !host.contains("..")
    }
}

/// Picks a reachable local IPv4 address for LAN pairing QR codes, avoiding loopback, link-local,
/// and tunnel interfaces when an Ethernet/Wi-Fi address is available.
public enum LocalNetworkAddress {
    public struct InterfaceAddress: Equatable, Sendable {
        public var name: String
        public var ip: String

        public init(name: String, ip: String) {
            self.name = name
            self.ip = ip
        }
    }

    public static func preferredIPv4() -> String? {
        preferredIPv4(from: activeIPv4Addresses())
    }

    public static func preferredIPv4(from candidates: [InterfaceAddress]) -> String? {
        let usable = candidates.filter { !isIgnored(ip: $0.ip) }
        if let primary = usable.first(where: { $0.name.hasPrefix("en") && isPrivateLAN($0.ip) }) {
            return primary.ip
        }
        if let anyEn = usable.first(where: { $0.name.hasPrefix("en") }) {
            return anyEn.ip
        }
        if let anyPrivate = usable.first(where: { !isVirtual($0.name) && isPrivateLAN($0.ip) }) {
            return anyPrivate.ip
        }
        return usable.first(where: { !isVirtual($0.name) })?.ip ?? usable.first?.ip
    }

    private static func activeIPv4Addresses() -> [InterfaceAddress] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(first) }

        var results: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp && !isLoopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let res = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if res == 0 {
                    let ip = String(decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    let name = String(cString: current.pointee.ifa_name)
                    results.append(InterfaceAddress(name: name, ip: ip))
                }
            }
            cursor = current.pointee.ifa_next
        }
        return results
    }

    private static func isIgnored(ip: String) -> Bool {
        ip.hasPrefix("127.") || ip.hasPrefix("169.254.")
    }

    private static func isVirtual(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("bridge")
    }

    private static func isPrivateLAN(_ ip: String) -> Bool {
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return true }
        let parts = ip.split(separator: ".")
        if parts.count == 4, parts[0] == "172", let second = Int(parts[1]), (16...31).contains(second) {
            return true
        }
        return false
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
