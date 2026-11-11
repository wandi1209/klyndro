import Foundation

/// Serialises Keychain mutations across test suites.
///
/// `SecKeyCreateRandomKey` with a permanent key started failing with `errSecItemNotFound` when
/// several suites generated identities at the same time. Test isolation is our job, not the
/// Keychain's, so every identity/trust mutation goes through this gate.
enum KeychainTestGate {
    private static let lock = NSLock()

    static func run<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
