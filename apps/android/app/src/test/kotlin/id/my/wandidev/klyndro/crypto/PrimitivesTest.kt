package id.my.wandidev.klyndro.crypto

import com.google.gson.JsonParser
import id.my.wandidev.klyndro.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FingerprintTest {

    @Test
    fun `parses a 64 character fingerprint and normalises case`() {
        val upper = "AB".repeat(32)
        val fingerprint = Fingerprint.parse(upper)
        assertNotNull(fingerprint)
        assertEquals(upper.lowercase(), fingerprint!!.hex)
    }

    @Test
    fun `rejects wrong length and non-hex input`() {
        assertNull(Fingerprint.parse(""))
        assertNull(Fingerprint.parse("a".repeat(63)))
        assertNull(Fingerprint.parse("a".repeat(65)))
        assertNull(Fingerprint.parse("z".repeat(64)))
    }

    @Test
    fun `matches is true only for identical values`() {
        val a = Fingerprint.parse("a".repeat(64))!!
        val b = Fingerprint.parse("b".repeat(64))!!
        assertTrue(a.matches(a))
        assertTrue(!a.matches(b))
        assertTrue(!a.matchesHex("nope"))
    }

    @Test
    fun `short form exposes only eight characters`() {
        assertEquals("abababab", Fingerprint.parse("ab".repeat(32))!!.shortHex)
    }

    @Test
    fun `nonces are 32 hex characters and unique`() {
        val first = Nonce.random()
        val second = Nonce.random()
        assertEquals(32, first.hex.length)
        assertTrue(first.hex != second.hex)
    }

    @Test
    fun `nonce parsing rejects bad input`() {
        assertNull(Nonce.parse("00"))
        assertNull(Nonce.parse("z".repeat(32)))
        assertNotNull(Nonce.parse("0".repeat(32)))
    }
}

class PairingCodeTest {

    /**
     * The vector was computed independently with Python's hashlib, so this test proves the Kotlin
     * implementation agrees with the specification rather than with the Swift implementation.
     */
    @Test
    fun `reproduces the independently computed vector`() {
        val document = JsonParser.parseString(
            Fixtures.text("protocol/vectors/pairing-sas.json")
        ).asJsonObject
        val vectors = document.getAsJsonArray("vectors")
        assertTrue("sas vector file is empty", vectors.size() > 0)

        vectors.forEach { element ->
            val vector = element.asJsonObject
            val peerA = vector.getAsJsonObject("peer_a")
            val peerB = vector.getAsJsonObject("peer_b")

            val fingerprintA = Fingerprint.parse(peerA.get("fingerprint").asString)!!
            val nonceA = Nonce.parse(peerA.get("nonce").asString)!!
            val fingerprintB = Fingerprint.parse(peerB.get("fingerprint").asString)!!
            val nonceB = Nonce.parse(peerB.get("nonce").asString)!!

            val code = PairingCode.derive(fingerprintA, nonceA, fingerprintB, nonceB)
            assertEquals("code mismatch", vector.get("code").asString, code.digits)
            assertEquals("digest mismatch", vector.get("digest").asString, code.digest.hex)

            val swapped = PairingCode.derive(fingerprintB, nonceB, fingerprintA, nonceA)
            assertEquals("ordering must not change the code", code.digits, swapped.digits)
            assertTrue(code.matchesDigest(swapped.digest.hex))
        }
    }

    @Test
    fun `always produces exactly six digits`() {
        repeat(50) {
            val code = PairingCode.derive(
                Fingerprint.ofSpki(Nonce.random().hex.toByteArray()),
                Nonce.random(),
                Fingerprint.ofSpki(Nonce.random().hex.toByteArray()),
                Nonce.random()
            )
            assertEquals(6, code.digits.length)
            assertTrue(code.digits.all { it.isDigit() })
        }
    }

    @Test
    fun `rejects a digest that differs in a single character`() {
        val code = PairingCode.derive(
            Fingerprint.ofSpki("a".toByteArray()),
            Nonce.random(),
            Fingerprint.ofSpki("b".toByteArray()),
            Nonce.random()
        )
        assertTrue(code.matchesDigest(code.digest.hex))

        val tampered = code.digest.hex.toCharArray()
        tampered[0] = if (tampered[0] == '0') '1' else '0'
        assertTrue(!code.matchesDigest(String(tampered)))
        assertTrue(!code.matchesDigest("not-hex"))
    }
}
