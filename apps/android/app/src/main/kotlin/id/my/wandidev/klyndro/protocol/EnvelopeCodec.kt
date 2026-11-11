package id.my.wandidev.klyndro.protocol

import com.google.gson.Gson
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParseException
import com.google.gson.JsonParser
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.UUID

/**
 * Envelope encode/decode with the validation order mandated by Klyndro Protocol v1 §4.
 *
 * Uses Gson's tree API rather than reflection: the schema is explicit, unknown fields are
 * preserved harmlessly, and there is no serialization compiler plugin to keep in sync
 * with the Android Gradle plugin's built-in Kotlin support.
 */
object EnvelopeCodec {
    private val gson = Gson()

    fun encode(envelope: Envelope): ByteArray {
        val root = JsonObject()
        root.addProperty("v", envelope.v)
        root.addProperty("id", envelope.id)
        root.addProperty("type", envelope.type)
        root.addProperty("ts", envelope.ts)
        // §4: an absent body is omitted, never encoded as null.
        envelope.body?.let { root.add("body", it) }

        val bytes = gson.toJson(root).toByteArray(Charsets.UTF_8)
        if (bytes.size > FramingLimits.MAX_ENVELOPE_BYTES) {
            throw ProtocolException.FrameTooLarge(bytes.size.toLong())
        }
        return bytes
    }

    fun frameFor(envelope: Envelope): Frame = Frame(FrameKind.ENVELOPE, encode(envelope))

    fun decode(payload: ByteArray): Envelope {
        if (payload.size > FramingLimits.MAX_ENVELOPE_BYTES) {
            throw ProtocolException.FrameTooLarge(payload.size.toLong())
        }

        val element = try {
            JsonParser.parseString(payload.decodeStrictUtf8())
        } catch (error: JsonParseException) {
            throw ProtocolException.MalformedEnvelope("unparseable json")
        }

        if (!element.isJsonObject) {
            throw ProtocolException.MalformedEnvelope("unparseable json")
        }

        val root = element.asJsonObject
        val version = root.requireInt("v")
        if (version != Envelope.CURRENT_VERSION) {
            throw ProtocolException.UnsupportedVersion(version)
        }

        val id = root.requireString("id")
        if (runCatching { UUID.fromString(id) }.isFailure) {
            throw ProtocolException.MalformedEnvelope("invalid field 'id'")
        }

        val type = root.requireString("type")
        if (type.isEmpty()) {
            throw ProtocolException.MalformedEnvelope("missing field 'type'")
        }

        val timestamp = root.requireLong("ts")
        val body = root.get("body")?.takeUnless { it.isJsonNull }?.let { element ->
            if (!element.isJsonObject) {
                throw ProtocolException.MalformedEnvelope("invalid field 'body'")
            }
            element.asJsonObject
        }

        return Envelope(v = version, id = id, type = type, ts = timestamp, body = body)
    }

    fun decode(frame: Frame): Envelope {
        if (frame.kind != FrameKind.ENVELOPE) throw ProtocolException.WrongFrameKind
        return decode(frame.payload)
    }

    /**
     * Kotlin's default UTF-8 decoding substitutes U+FFFD for invalid bytes, which would
     * let corrupt input decode as a mangled envelope. Report instead.
     */
    private fun ByteArray.decodeStrictUtf8(): String {
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(ByteBuffer.wrap(this)).toString()
        } catch (_: CharacterCodingException) {
            throw ProtocolException.MalformedEnvelope("invalid utf-8")
        }
    }

    private fun JsonObject.requireElement(name: String): JsonElement =
        get(name)?.takeUnless { it.isJsonNull }
            ?: throw ProtocolException.MalformedEnvelope("missing field '$name'")

    private fun JsonObject.requireInt(name: String): Int {
        val element = requireElement(name)
        val primitive = element.takeIf { it.isJsonPrimitive }?.asJsonPrimitive
        if (primitive == null || !primitive.isNumber) {
            throw ProtocolException.MalformedEnvelope("invalid field '$name'")
        }
        return primitive.asString.toIntOrNull()
            ?: throw ProtocolException.MalformedEnvelope("invalid field '$name'")
    }

    private fun JsonObject.requireLong(name: String): Long {
        val element = requireElement(name)
        val primitive = element.takeIf { it.isJsonPrimitive }?.asJsonPrimitive
        if (primitive == null || !primitive.isNumber) {
            throw ProtocolException.MalformedEnvelope("invalid field '$name'")
        }
        return primitive.asString.toLongOrNull()
            ?: throw ProtocolException.MalformedEnvelope("invalid field '$name'")
    }

    private fun JsonObject.requireString(name: String): String {
        val element = requireElement(name)
        val primitive = element.takeIf { it.isJsonPrimitive }?.asJsonPrimitive
        if (primitive == null || !primitive.isString) {
            throw ProtocolException.MalformedEnvelope("invalid field '$name'")
        }
        return primitive.asString
    }
}
