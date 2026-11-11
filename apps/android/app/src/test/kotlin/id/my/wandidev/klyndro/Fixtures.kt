package id.my.wandidev.klyndro

import java.io.File
import org.junit.Assert.assertNotNull

/** Locates shared protocol artifacts relative to the Gradle test working directory. */
object Fixtures {
    private val roots = listOf("../..", "../../..", ".")

    fun file(relativePath: String): File {
        val found = roots.map { File(it, relativePath) }.firstOrNull { it.isFile }
        assertNotNull("could not locate $relativePath from ${File(".").absolutePath}", found)
        return requireNotNull(found)
    }

    fun text(relativePath: String): String = file(relativePath).readText()
}
