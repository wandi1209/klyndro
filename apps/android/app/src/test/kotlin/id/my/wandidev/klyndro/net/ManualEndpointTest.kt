package id.my.wandidev.klyndro.net

import id.my.wandidev.klyndro.crypto.TrustedPeer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ManualEndpointTest {

    @Test
    fun `parses ipv4 with default port and explicit port`() {
        assertEquals(
            ManualEndpoint("192.168.1.25", 47823),
            ManualEndpoint.parse(" 192.168.1.25 ")
        )
        assertEquals(
            ManualEndpoint("192.168.1.25", 50000),
            ManualEndpoint.parse("192.168.1.25:50000")
        )
    }

    @Test
    fun `parses local hostname with and without port`() {
        assertEquals(
            ManualEndpoint("wandi-macbook.local", 47823),
            ManualEndpoint.parse("wandi-macbook.local")
        )
        assertEquals(
            ManualEndpoint("wandi-macbook.local", 47823),
            ManualEndpoint.parse("wandi-macbook.local:47823")
        )
    }

    @Test
    fun `rejects invalid hosts, ports, schemes, and whitespace`() {
        val bad = listOf(
            "",
            "   ",
            "192.168.1",
            "192.168.1.256",
            "192.168.1.1:0",
            "192.168.1.1:65536",
            "192.168.1.1:abc",
            "192.168.1.1:",
            "http://192.168.1.1",
            "192.168.1.1/pair",
            "192.168.1.1 47823",
            "-bad.local",
            "bad..local",
            "::1:47823"
        )
        for (input in bad) {
            assertNull("expected rejection for '$input'", ManualEndpoint.parse(input))
        }
    }

    @Test
    fun `resolvePersistHost prefers non-loopback LAN host over USB loopback`() {
        assertEquals(
            "192.168.23.101",
            PeerAddressPolicy.resolvePersistHost(
                dialHost = "127.0.0.1",
                preferredHost = "192.168.23.101",
                discoveredHost = null
            )
        )
        assertEquals(
            "192.168.23.102",
            PeerAddressPolicy.resolvePersistHost(
                dialHost = "127.0.0.1",
                preferredHost = "127.0.0.1",
                discoveredHost = "192.168.23.102"
            )
        )
        assertEquals(
            "127.0.0.1",
            PeerAddressPolicy.resolvePersistHost(
                dialHost = "127.0.0.1",
                preferredHost = null,
                discoveredHost = null
            )
        )
    }

    @Test
    fun `updatedPeerOnConnect heals stale loopback and DHCP host without clobbering LAN IP`() {
        val usbPaired = TrustedPeer(
            deviceId = "a".repeat(16),
            name = "Mac",
            platform = "macos",
            fingerprint = "b".repeat(64),
            lastHost = "127.0.0.1",
            lastPort = 47823
        )
        val healedFromMdns = PeerAddressPolicy.updatedPeerOnConnect(usbPaired, "192.168.23.101", 47823)
        assertEquals("192.168.23.101", healedFromMdns?.lastHost)
        assertEquals(47823, healedFromMdns?.lastPort)

        val lanPaired = usbPaired.copy(lastHost = "192.168.23.101")
        assertNull(PeerAddressPolicy.updatedPeerOnConnect(lanPaired, "192.168.23.101", 47823))
        assertNull(PeerAddressPolicy.updatedPeerOnConnect(lanPaired, "127.0.0.1", 47823))

        val dhcpChanged = PeerAddressPolicy.updatedPeerOnConnect(lanPaired, "192.168.23.105", 47824)
        assertEquals("192.168.23.105", dhcpChanged?.lastHost)
        assertEquals(47824, dhcpChanged?.lastPort)

        assertTrue(PeerAddressPolicy.isLoopbackHost("127.0.0.1"))
        assertFalse(PeerAddressPolicy.isLoopbackHost("192.168.23.101"))
    }
}
