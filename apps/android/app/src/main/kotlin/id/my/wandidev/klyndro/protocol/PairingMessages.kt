package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonObject
import id.my.wandidev.klyndro.crypto.Fingerprint
import id.my.wandidev.klyndro.crypto.Nonce

/** Body of `pair.request` (protocol §5.4). */
data class PairRequestBody(
    val deviceId: DeviceId,
    val deviceName: String,
    val platform: Platform,
    val fingerprint: Fingerprint,
    val nonce: Nonce,
    val protocolVersion: Int,
    val capabilities: List<Capability>
) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("device_id", deviceId.hex)
        addProperty("device_name", deviceName)
        addProperty("platform", platform.wireName)
        addProperty("fingerprint", fingerprint.hex)
        addProperty("nonce", nonce.hex)
        addProperty("protocol_version", protocolVersion)
        add(
            "capabilities",
            com.google.gson.JsonArray().apply { capabilities.forEach { add(it.wireName) } }
        )
    }
}

/** Body of `pair.confirm` (protocol §5.4). */
data class PairConfirmBody(
    val fingerprint: Fingerprint,
    val nonce: Nonce,
    val sasDigest: Fingerprint
) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("fingerprint", fingerprint.hex)
        addProperty("nonce", nonce.hex)
        addProperty("sas_digest", sasDigest.hex)
    }
}

/** Why a pairing attempt failed; values match the `reason` field. */
enum class PairingFailure(val wireName: String) {
    USER_REJECTED("user_rejected"),
    SAS_MISMATCH("sas_mismatch"),
    WINDOW_CLOSED("window_closed"),
    RATE_LIMITED("rate_limited"),
    ALREADY_PAIRED("already_paired"),
    INTERNAL("internal");

    companion object {
        fun fromWire(value: String): PairingFailure? = entries.firstOrNull { it.wireName == value }
    }
}

/** Body of `pair.result` (protocol §5.4). */
data class PairResultBody(val accepted: Boolean, val reason: PairingFailure? = null) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("accepted", accepted)
        reason?.let { addProperty("reason", it.wireName) }
    }
}

sealed class PairingMessageException(message: String) : Exception(message) {
    data class MissingField(val name: String) : PairingMessageException("missing field '$name'")
    data class InvalidField(val name: String) : PairingMessageException("invalid field '$name'")
    data class NotAPairingMessage(val type: MessageType) :
        PairingMessageException("${type.wireName} is not a pairing message")
}

/** Encoding and validation for the three pairing messages. */
object PairingMessageCodec {

    fun decodeRequest(envelope: Envelope): PairRequestBody {
        if (envelope.messageType != MessageType.PAIR_REQUEST) {
            throw PairingMessageException.NotAPairingMessage(envelope.messageType)
        }
        val body = envelope.body ?: throw PairingMessageException.MissingField("body")

        val deviceId = DeviceId.parse(
            body.stringOrNull("device_id") ?: throw PairingMessageException.MissingField("device_id")
        ) ?: throw PairingMessageException.InvalidField("device_id")

        val name = body.stringOrNull("device_name")
            ?: throw PairingMessageException.MissingField("device_name")
        if (name.isEmpty() || name.toByteArray(Charsets.UTF_8).size > ProtocolLimits.MAX_DEVICE_NAME_BYTES) {
            throw PairingMessageException.InvalidField("device_name")
        }

        val platform = Platform.fromWire(
            body.stringOrNull("platform") ?: throw PairingMessageException.InvalidField("platform")
        ) ?: throw PairingMessageException.InvalidField("platform")

        val fingerprint = Fingerprint.parse(
            body.stringOrNull("fingerprint")
                ?: throw PairingMessageException.MissingField("fingerprint")
        ) ?: throw PairingMessageException.InvalidField("fingerprint")

        val nonce = Nonce.parse(
            body.stringOrNull("nonce") ?: throw PairingMessageException.MissingField("nonce")
        ) ?: throw PairingMessageException.InvalidField("nonce")

        val version = body.intOrNull("protocol_version")
            ?: throw PairingMessageException.MissingField("protocol_version")
        if (version != Envelope.CURRENT_VERSION) {
            throw PairingMessageException.InvalidField("protocol_version")
        }

        val capabilities = body.getAsJsonArray("capabilities")
            ?.map { it.asString }
            ?: throw PairingMessageException.MissingField("capabilities")

        return PairRequestBody(
            deviceId = deviceId,
            deviceName = name,
            platform = platform,
            fingerprint = fingerprint,
            nonce = nonce,
            protocolVersion = version,
            capabilities = Capability.parse(capabilities)
        )
    }

    fun decodeConfirm(envelope: Envelope): PairConfirmBody {
        if (envelope.messageType != MessageType.PAIR_CONFIRM) {
            throw PairingMessageException.NotAPairingMessage(envelope.messageType)
        }
        val body = envelope.body ?: throw PairingMessageException.MissingField("body")

        return PairConfirmBody(
            fingerprint = Fingerprint.parse(body.stringOrNull("fingerprint") ?: "")
                ?: throw PairingMessageException.InvalidField("fingerprint"),
            nonce = Nonce.parse(body.stringOrNull("nonce") ?: "")
                ?: throw PairingMessageException.InvalidField("nonce"),
            sasDigest = Fingerprint.parse(body.stringOrNull("sas_digest") ?: "")
                ?: throw PairingMessageException.InvalidField("sas_digest")
        )
    }

    fun decodeResult(envelope: Envelope): PairResultBody {
        if (envelope.messageType != MessageType.PAIR_RESULT) {
            throw PairingMessageException.NotAPairingMessage(envelope.messageType)
        }
        val body = envelope.body ?: throw PairingMessageException.MissingField("body")
        val accepted = body.get("accepted")
            ?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isBoolean }
            ?.asBoolean
            ?: throw PairingMessageException.MissingField("accepted")
        val reason = body.stringOrNull("reason")?.let { PairingFailure.fromWire(it) }
        return PairResultBody(accepted = accepted, reason = reason)
    }
}
