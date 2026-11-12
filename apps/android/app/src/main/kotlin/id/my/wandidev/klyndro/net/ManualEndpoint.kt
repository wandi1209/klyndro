package id.my.wandidev.klyndro.net

import id.my.wandidev.klyndro.crypto.TrustedPeer

/**
 * Validated host and port entered manually by the user when mDNS discovery is unavailable (F01).
 */
data class ManualEndpoint(val host: String, val port: Int) {

    companion object {
        const val DEFAULT_PORT = 47_823

        /**
         * Parses `host` or `host:port` into a [ManualEndpoint], defaulting the port to [defaultPort].
         * Accepts IPv4 literals and plain hostnames (for example `mac.local`); rejects whitespace,
         * URL schemes, paths, and out-of-range ports or octets.
         */
        fun parse(raw: String, defaultPort: Int = DEFAULT_PORT): ManualEndpoint? {
            val trimmed = raw.trim()
            if (trimmed.isEmpty() || trimmed.any { it.isWhitespace() }) return null

            val colonIndex = trimmed.indexOf(':')
            val host: String
            val port: Int
            if (colonIndex >= 0) {
                // Reject multiple colons (unbracketed IPv6 or extra separators).
                if (trimmed.indexOf(':', colonIndex + 1) >= 0) return null
                host = trimmed.substring(0, colonIndex)
                val portStr = trimmed.substring(colonIndex + 1)
                val parsedPort = portStr.toIntOrNull() ?: return null
                if (parsedPort !in 1..65535) return null
                port = parsedPort
            } else {
                host = trimmed
                port = defaultPort
            }

            if (!isValidHost(host)) return null
            return ManualEndpoint(host, port)
        }

        private fun isValidHost(host: String): Boolean {
            if (host.isEmpty() || host.length > 253) return false
            if (host.any { !it.isLetterOrDigit() && it != '.' && it != '-' }) return false
            if (host.startsWith('.') || host.endsWith('.') || host.contains("..")) return false

            // Dotted all-numeric strings must be valid IPv4 octets, not arbitrary numbers like 999.1.2.3.
            val labels = host.split('.')
            if (labels.all { label -> label.isNotEmpty() && label.all { it.isDigit() } }) {
                if (labels.size != 4) return false
                return labels.all { octet ->
                    val value = octet.toIntOrNull() ?: return@all false
                    value in 0..255
                }
            }

            return labels.all { label ->
                label.isNotEmpty() &&
                    label.length <= 63 &&
                    !label.startsWith('-') &&
                    !label.endsWith('-')
            }
        }
    }
}

/**
 * Keeps a paired peer's persisted `lastHost`/`lastPort` pointed at a reachable LAN address instead
 * of a transient USB loopback (`127.0.0.1`) or stale DHCP address.
 */
object PeerAddressPolicy {

    fun isLoopbackHost(host: String?): Boolean =
        host == "127.0.0.1" || host.equals("localhost", ignoreCase = true) || host == "::1"

    fun resolvePersistHost(
        dialHost: String,
        preferredHost: String?,
        discoveredHost: String?
    ): String {
        if (!preferredHost.isNullOrBlank() && !isLoopbackHost(preferredHost)) return preferredHost
        if (!discoveredHost.isNullOrBlank() && !isLoopbackHost(discoveredHost)) return discoveredHost
        return dialHost
    }

    fun updatedPeerOnConnect(
        peer: TrustedPeer,
        connectedHost: String,
        connectedPort: Int
    ): TrustedPeer? {
        if (isLoopbackHost(connectedHost) && peer.lastHost != null && !isLoopbackHost(peer.lastHost)) {
            return null
        }
        if (peer.lastHost == connectedHost && peer.lastPort == connectedPort) {
            return null
        }
        return peer.copy(lastHost = connectedHost, lastPort = connectedPort)
    }
}
