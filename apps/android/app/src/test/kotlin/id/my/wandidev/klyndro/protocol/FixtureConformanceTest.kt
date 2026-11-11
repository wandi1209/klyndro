package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Decoder conformance against the shared fixtures in `protocol/fixtures`, which the macOS
 * test suite reads as well. If these two suites disagree, the protocol has silently forked.
 */
class FixtureConformanceTest {

    private data class Entry(val file: String, val expect: String, val type: String?)

    private val directory: File = locateFixturesDirectory()
    private val entries: List<Entry> = loadManifest()

    @Test
    fun `manifest agrees with the fixture directory`() {
        assertEquals(
            Envelope.CURRENT_VERSION,
            manifest().get("protocol_version").asInt
        )

        val onDisk = requireNotNull(directory.listFiles()) { "fixtures directory is unreadable" }
            .filter { it.isFile && it.name.endsWith(".json") && it.name != "manifest.json" }
            .map { it.name }
            .sorted()

        assertEquals(onDisk, entries.map { it.file }.sorted())
    }

    @Test
    fun `every fixture produces the declared decoder outcome`() {
        assertTrue("manifest is empty", entries.isNotEmpty())

        entries.forEach { entry ->
            val payload = File(directory, entry.file).readBytes()

            when (entry.expect) {
                "valid" -> {
                    val envelope = EnvelopeCodec.decode(payload)
                    assertEquals("${entry.file}: type mismatch", entry.type, envelope.type)
                    assertTrue("${entry.file}: expected a known type", envelope.messageType.isKnown)
                }

                "unknown_type" -> {
                    val envelope = EnvelopeCodec.decode(payload)
                    assertEquals("${entry.file}: type mismatch", entry.type, envelope.type)
                    assertFalse("${entry.file}: expected an unknown type", envelope.messageType.isKnown)
                }

                "malformed" -> assertThrows(
                    "${entry.file}: expected a rejection",
                    ProtocolException::class.java
                ) {
                    EnvelopeCodec.decode(payload)
                }

                else -> fail("Unknown expectation '${entry.expect}' in manifest for ${entry.file}")
            }
        }
    }

    @Test
    fun `re-encoding a fixture preserves its meaning`() {
        entries.filter { it.expect != "malformed" }.forEach { entry ->
            val payload = File(directory, entry.file).readBytes()
            val original = EnvelopeCodec.decode(payload)
            val roundTripped = EnvelopeCodec.decode(EnvelopeCodec.encode(original))

            assertEquals("${entry.file}: version changed", original.v, roundTripped.v)
            assertEquals("${entry.file}: id changed", original.id, roundTripped.id)
            assertEquals("${entry.file}: type changed", original.type, roundTripped.type)
            assertEquals("${entry.file}: timestamp changed", original.ts, roundTripped.ts)
            assertEquals(
                "${entry.file}: body changed",
                original.body?.toString() ?: "<none>",
                roundTripped.body?.toString() ?: "<none>"
            )
        }
    }

    private fun loadManifest(): List<Entry> {
        val fixtures = manifest().getAsJsonArray("fixtures")
        assertNotNull("manifest has no fixtures array", fixtures)
        return fixtures.map { element ->
            val entry = element.asJsonObject
            Entry(
                file = entry.get("file").asString,
                expect = entry.get("expect").asString,
                type = entry.get("type")?.takeUnless { it.isJsonNull }?.asString
            )
        }
    }

    private fun manifest(): JsonObject =
        JsonParser.parseString(File(directory, "manifest.json").readText()).asJsonObject

    private fun locateFixturesDirectory(): File {
        val candidates = listOf(
            "../../../protocol/fixtures",
            "../../protocol/fixtures",
            "../protocol/fixtures",
            "protocol/fixtures"
        )
        val found = candidates
            .map { File(it) }
            .map { it.normalize() }
            .firstOrNull { File(it, "manifest.json").isFile }

        assertNotNull(
            "protocol fixtures not found; looked from ${File(".").absolutePath}",
            found
        )
        return requireNotNull(found)
    }
}
