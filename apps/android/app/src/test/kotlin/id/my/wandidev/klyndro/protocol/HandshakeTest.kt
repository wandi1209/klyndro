package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonObject
import id.my.wandidev.klyndro.crypto.DeviceIdentity
import id.my.wandidev.klyndro.crypto.Fingerprint
import id.my.wandidev.klyndro.crypto.Nonce
import id.my.wandidev.klyndro.net.PinDecision
import id.my.wandidev.klyndro.net.PinPolicy
import id.my.wandidev.klyndro.net.PinRejection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HandshakeTest {

    private val deviceId = DeviceId.parse("a1b2c3d4e5f60718")!!
    private val nonce = Nonce.random()

    private fun hello(
        capabilities: List<Capability> = listOf(Capability.CLIPBOARD, Capability.NOTIFICATIONS)
    ) = HelloBody(
        deviceId = deviceId,
        deviceName = "Test Android",
        platform = Platform.ANDROID,
        appVersion = "0.1.0",
        protocolVersion = Envelope.CURRENT_VERSION,
        capabilities = capabilities,
        nonce = nonce.hex
    )

    @Test
    fun `round trips hello`() {
        val envelope = Envelope(
            v = 1,
            id = java.util.UUID.randomUUID().toString(),
            type = MessageType.HELLO.wireName!!,
            ts = 1_762_800_000_000,
            body = hello().toJson()
        )
        val decoded = HandshakeCodec.decodeHello(envelope)
        assertEquals(deviceId, decoded.deviceId)
        assertEquals("Test Android", decoded.deviceName)
        assertEquals(Platform.ANDROID, decoded.platform)
        assertEquals(listOf(Capability.CLIPBOARD, Capability.NOTIFICATIONS), decoded.capabilities)
        assertEquals(nonce.hex, decoded.nonce)
    }

    @Test
    fun `round trips hello ack and keeps the echo nonce`() {
        val envelope = Envelope(
            v = 1,
            id = java.util.UUID.randomUUID().toString(),
            type = MessageType.HELLO_ACK.wireName!!,
            ts = 1,
            body = hello().toAckJson(nonce.hex)
        )
        val (decoded, echo) = HandshakeCodec.decodeHelloAck(envelope)
        assertEquals(nonce.hex, echo)
        assertEquals(deviceId, decoded.deviceId)
    }

    @Test
    fun `rejects a missing field, naming it`() {
        val body = hello().toJson().apply { remove("device_name") }
        val error = assertThrows(HandshakeException.MissingField::class.java) {
            HandshakeCodec.parseHelloBody(body)
        }
        assertEquals("device_name", error.name)
    }

    @Test
    fun `rejects an invalid device id`() {
        val body = hello().toJson().apply { addProperty("device_id", "too-short") }
        assertThrows(HandshakeException.InvalidField::class.java) {
            HandshakeCodec.parseHelloBody(body)
        }
    }

    @Test
    fun `rejects an unknown platform and an unsupported version`() {
        assertThrows(HandshakeException.InvalidField::class.java) {
            HandshakeCodec.parseHelloBody(hello().toJson().apply { addProperty("platform", "windows") })
        }
        val error = assertThrows(HandshakeException.UnsupportedProtocolVersion::class.java) {
            HandshakeCodec.parseHelloBody(hello().toJson().apply { addProperty("protocol_version", 2) })
        }
        assertEquals(2, error.version)
    }

    @Test
    fun `rejects an oversized device name`() {
        assertThrows(HandshakeException.InvalidField::class.java) {
            HandshakeCodec.parseHelloBody(hello().toJson().apply { addProperty("device_name", "x".repeat(257)) })
        }
    }

    @Test
    fun `detects a replayed acknowledgement`() {
        assertThrows(HandshakeException.NonceEchoMismatch::class.java) {
            HandshakeCodec.verifyEcho(Nonce.random().hex, nonce.hex)
        }
    }

    @Test
    fun `ignores unknown capabilities but keeps known ones`() {
        assertEquals(
            listOf(Capability.CLIPBOARD, Capability.MIRRORING),
            Capability.parse(listOf("clipboard", "teleportation", "mirroring"))
        )
    }

    @Test
    fun `negotiation is the intersection in declaration order`() {
        assertEquals(
            listOf(Capability.MIRRORING, Capability.PRESENCE),
            Capability.negotiate(
                listOf(Capability.PRESENCE, Capability.CLIPBOARD, Capability.MIRRORING),
                listOf(Capability.MIRRORING, Capability.PRESENCE, Capability.FILE_TRANSFER)
            )
        )
    }
}

class PairingMessagesTest {

    private val fingerprint = Fingerprint.ofSpki("peer key".toByteArray())
    private val nonce = Nonce.random()

    private fun request() = PairRequestBody(
        deviceId = DeviceId.parse("a1b2c3d4e5f60718")!!,
        deviceName = "Phone",
        platform = Platform.ANDROID,
        fingerprint = fingerprint,
        nonce = nonce,
        protocolVersion = Envelope.CURRENT_VERSION,
        capabilities = listOf(Capability.CLIPBOARD)
    )

    @Test
    fun `round trips pair request`() {
        val envelope = Envelope(1, java.util.UUID.randomUUID().toString(), MessageType.PAIR_REQUEST.wireName!!, 1, request().toJson())
        assertEquals(request(), PairingMessageCodec.decodeRequest(envelope))
    }

    @Test
    fun `round trips pair confirm`() {
        val body = PairConfirmBody(fingerprint, nonce, Fingerprint.ofSpki("digest".toByteArray()))
        val envelope = Envelope(1, java.util.UUID.randomUUID().toString(), MessageType.PAIR_CONFIRM.wireName!!, 1, body.toJson())
        assertEquals(body, PairingMessageCodec.decodeConfirm(envelope))
    }

    @Test
    fun `round trips pair result with and without a reason`() {
        val accepted = Envelope(1, java.util.UUID.randomUUID().toString(), MessageType.PAIR_RESULT.wireName!!, 1, PairResultBody(true).toJson())
        assertEquals(PairResultBody(true, null), PairingMessageCodec.decodeResult(accepted))

        val refused = Envelope(1, java.util.UUID.randomUUID().toString(), MessageType.PAIR_RESULT.wireName!!, 1, PairResultBody(false, PairingFailure.SAS_MISMATCH).toJson())
        assertEquals(PairResultBody(false, PairingFailure.SAS_MISMATCH), PairingMessageCodec.decodeResult(refused))
    }

    @Test
    fun `rejects a malformed fingerprint`() {
        val body: JsonObject = request().toJson().apply { addProperty("fingerprint", "abc") }
        val envelope = Envelope(1, java.util.UUID.randomUUID().toString(), MessageType.PAIR_REQUEST.wireName!!, 1, body)
        assertThrows(PairingMessageException.InvalidField::class.java) {
            PairingMessageCodec.decodeRequest(envelope)
        }
    }

    @Test
    fun `refuses to decode a non-pairing message`() {
        val envelope = Envelope(1, java.util.UUID.randomUUID().toString(), MessageType.PING.wireName!!, 1, null)
        assertThrows(PairingMessageException.NotAPairingMessage::class.java) {
            PairingMessageCodec.decodeRequest(envelope)
        }
    }
}

class PinPolicyTest {

    private fun certificate(commonName: String): DeviceIdentity =
        DeviceIdentity.createSelfSigned(commonName, DeviceIdentity.generateKeyPair())

    @Test
    fun `accepts a pinned fingerprint`() {
        val identity = certificate("Peer")
        val decision = PinPolicy.pinned(setOf(identity.fingerprint))
            .evaluate(identity.certificateDer)

        assertTrue(decision is PinDecision.Accepted)
        val accepted = decision as PinDecision.Accepted
        assertTrue(accepted.isPinned)
        assertTrue(accepted.fingerprint.matches(identity.fingerprint))
    }

    @Test
    fun `rejects an unpinned fingerprint`() {
        val identity = certificate("Stranger")
        val stranger = Fingerprint.ofSpki("someone else".toByteArray())
        val decision = PinPolicy.pinned(setOf(stranger)).evaluate(identity.certificateDer)

        assertTrue(decision is PinDecision.Rejected)
        assertTrue((decision as PinDecision.Rejected).reason is PinRejection.FingerprintNotTrusted)
    }

    @Test
    fun `rejects everything when nothing is paired`() {
        val identity = certificate("Peer")
        val decision = PinPolicy.pinned(emptySet()).evaluate(identity.certificateDer)
        assertEquals(PinDecision.Rejected(PinRejection.NoPairedPeers), decision)
    }

    @Test
    fun `the pairing window accepts an unknown but readable certificate`() {
        val identity = certificate("New Phone")
        val decision = PinPolicy.PAIRING_ONLY.evaluate(identity.certificateDer)

        assertTrue(decision is PinDecision.Accepted)
        val accepted = decision as PinDecision.Accepted
        assertFalse("pairing-window peers are authenticated per-connection, not pinned", accepted.isPinned)
        assertTrue(accepted.fingerprint.matches(identity.fingerprint))
    }

    @Test
    fun `rejects an unreadable certificate in both modes`() {
        val garbage = byteArrayOf(0x00, 0x01, 0x02)
        assertEquals(
            PinDecision.Rejected(PinRejection.UnparsableCertificate),
            PinPolicy.PAIRING_ONLY.evaluate(garbage)
        )
        assertEquals(
            PinDecision.Rejected(PinRejection.UnparsableCertificate),
            PinPolicy.pinned(emptySet()).evaluate(garbage)
        )
    }

    @Test
    fun `fingerprint is taken over the SPKI, not the whole certificate`() {
        val identity = certificate("Peer")
        val fromCertificate = PinPolicy.fingerprintOf(identity.certificateDer)
        val fromKey = Fingerprint.ofSpki(identity.certificate.publicKey.encoded)
        assertTrue(fromCertificate.matches(fromKey))
        assertNotNull(identity.fingerprint)
        assertEquals(64, fromCertificate.hex.length)
    }
}
