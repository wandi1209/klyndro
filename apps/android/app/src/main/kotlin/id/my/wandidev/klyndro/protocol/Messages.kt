package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonObject

/** Feature flags exchanged in `hello` (protocol §5.1). */
enum class Capability(val wireName: String) {
    CLIPBOARD("clipboard"),
    CLIPBOARD_SENSITIVE("clipboard.sensitive"),
    NOTIFICATIONS("notifications"),
    FILE_TRANSFER("file-transfer"),
    MIRRORING("mirroring"),
    PRESENCE("presence");

    companion object {
        /** Unknown capability strings from a newer peer are ignored, not rejected. */
        fun parse(values: List<String>): List<Capability> {
            val known = values.mapNotNull { value -> entries.firstOrNull { it.wireName == value } }.toSet()
            // Stable order so negotiated output is comparable across platforms.
            return entries.filter { it in known }
        }

        /** Intersection, in declaration order. */
        fun negotiate(local: List<Capability>, remote: List<Capability>): List<Capability> =
            entries.filter { it in local && it in remote }
    }
}

/** Platform identifier used on the wire. */
enum class Platform(val wireName: String) {
    MACOS("macos"),
    ANDROID("android");

    companion object {
        fun fromWire(value: String): Platform? = entries.firstOrNull { it.wireName == value }
    }
}

/** Stable device identifier: 16 lowercase hex characters, generated once per installation. */
class DeviceId private constructor(val hex: String) {

    override fun equals(other: Any?): Boolean = other is DeviceId && other.hex == hex
    override fun hashCode(): Int = hex.hashCode()
    override fun toString(): String = hex

    companion object {
        const val HEX_LENGTH = 16

        fun parse(value: String): DeviceId? =
            if (value.length == HEX_LENGTH && value.all { it.isHexDigit() }) {
                DeviceId(value.lowercase())
            } else {
                null
            }

        fun random(random: java.security.SecureRandom = java.security.SecureRandom()): DeviceId {
            val bytes = ByteArray(HEX_LENGTH / 2)
            random.nextBytes(bytes)
            return DeviceId(bytes.toHexString())
        }
    }
}

/** Device name and app version bounds, shared with the Swift implementation. */
object ProtocolLimits {
    const val MAX_DEVICE_NAME_BYTES = 256
    const val MAX_APP_VERSION_BYTES = 64
}

/** Body of `hello` (protocol §5.1). */
data class HelloBody(
    val deviceId: DeviceId,
    val deviceName: String,
    val platform: Platform,
    val appVersion: String,
    val protocolVersion: Int,
    val capabilities: List<Capability>,
    val nonce: String
) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("device_id", deviceId.hex)
        addProperty("device_name", deviceName)
        addProperty("platform", platform.wireName)
        addProperty("app_version", appVersion)
        addProperty("protocol_version", protocolVersion)
        add(
            "capabilities",
            com.google.gson.JsonArray().apply {
                capabilities.forEach { add(it.wireName) }
            }
        )
        addProperty("nonce", nonce)
    }

    /** Same fields plus the echo, for `hello.ack`. */
    fun toAckJson(echoNonce: String): JsonObject = toJson().apply {
        addProperty("echo_nonce", echoNonce)
    }
}

sealed class HandshakeException(message: String) : Exception(message) {
    data class WrongMessageType(val expected: MessageType) :
        HandshakeException("expected ${expected.wireName}")

    data class UnsupportedProtocolVersion(val version: Int) :
        HandshakeException("peer speaks protocol version $version")

    data class MissingField(val name: String) : HandshakeException("missing field '$name'")

    data class InvalidField(val name: String) : HandshakeException("invalid field '$name'")

    object NonceEchoMismatch : HandshakeException("nonce echo did not match; possible replay")
}

/** Encoding and validation for the session handshake, mirroring `HandshakeCodec`. */
object HandshakeCodec {

    fun decodeHello(envelope: Envelope): HelloBody {
        if (envelope.messageType != MessageType.HELLO) {
            throw HandshakeException.WrongMessageType(MessageType.HELLO)
        }
        return parseHelloBody(envelope.body)
    }

    /** Returns the peer's hello plus its echoed nonce. */
    fun decodeHelloAck(envelope: Envelope): Pair<HelloBody, String> {
        if (envelope.messageType != MessageType.HELLO_ACK) {
            throw HandshakeException.WrongMessageType(MessageType.HELLO_ACK)
        }
        val hello = parseHelloBody(envelope.body)
        val echo = envelope.body?.get("echo_nonce")?.takeIf { it.isJsonPrimitive }
            ?.asString ?: throw HandshakeException.MissingField("echo_nonce")
        if (echo.length != 32 || !echo.all { it.isHexDigit() }) {
            throw HandshakeException.InvalidField("echo_nonce")
        }
        return hello to echo.lowercase()
    }

    fun verifyEcho(echo: String, expected: String) {
        if (!echo.equals(expected, ignoreCase = true)) throw HandshakeException.NonceEchoMismatch
    }

    fun parseHelloBody(body: JsonObject?): HelloBody {
        if (body == null) throw HandshakeException.MissingField("body")

        val deviceIdRaw = body.stringOrNull("device_id")
            ?: throw HandshakeException.MissingField("device_id")
        val deviceId = DeviceId.parse(deviceIdRaw)
            ?: throw HandshakeException.InvalidField("device_id")

        val name = body.stringOrNull("device_name")
            ?: throw HandshakeException.MissingField("device_name")
        if (name.isEmpty() || name.toByteArray(Charsets.UTF_8).size > ProtocolLimits.MAX_DEVICE_NAME_BYTES) {
            throw HandshakeException.InvalidField("device_name")
        }

        val platformRaw = body.stringOrNull("platform")
            ?: throw HandshakeException.InvalidField("platform")
        val platform = Platform.fromWire(platformRaw)
            ?: throw HandshakeException.InvalidField("platform")

        val appVersion = body.stringOrNull("app_version")
            ?: throw HandshakeException.MissingField("app_version")
        if (appVersion.toByteArray(Charsets.UTF_8).size > ProtocolLimits.MAX_APP_VERSION_BYTES) {
            throw HandshakeException.InvalidField("app_version")
        }

        val version = body.intOrNull("protocol_version")
            ?: throw HandshakeException.MissingField("protocol_version")
        if (version != Envelope.CURRENT_VERSION) {
            throw HandshakeException.UnsupportedProtocolVersion(version)
        }

        val capabilitiesArray = body.getAsJsonArray("capabilities")
            ?: throw HandshakeException.MissingField("capabilities")
        val capabilities = capabilitiesArray.map {
            if (!it.isJsonPrimitive || !it.asJsonPrimitive.isString) {
                throw HandshakeException.InvalidField("capabilities")
            }
            it.asString
        }

        val nonce = body.stringOrNull("nonce") ?: throw HandshakeException.MissingField("nonce")
        if (nonce.length != 32 || !nonce.all { it.isHexDigit() }) {
            throw HandshakeException.InvalidField("nonce")
        }

        return HelloBody(
            deviceId = deviceId,
            deviceName = name,
            platform = platform,
            appVersion = appVersion,
            protocolVersion = version,
            capabilities = Capability.parse(capabilities),
            nonce = nonce.lowercase()
        )
    }
}

internal fun JsonObject.stringOrNull(name: String): String? =
    get(name)?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isString }?.asString

internal fun JsonObject.intOrNull(name: String): Int? {
    val element = get(name)?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isNumber } ?: return null
    return element.asString.toIntOrNull()
}

internal fun Char.isHexDigit(): Boolean =
    this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'

internal fun ByteArray.toHexString(): String {
    val digits = "0123456789abcdef"
    val output = StringBuilder(size * 2)
    for (byte in this) {
        val value = byte.toInt() and 0xFF
        output.append(digits[value ushr 4])
        output.append(digits[value and 0x0F])
    }
    return output.toString()
}
