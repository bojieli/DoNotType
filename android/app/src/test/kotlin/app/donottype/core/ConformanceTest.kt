package app.donottype.core

import java.io.File
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Checks this port of [ContextEncoder] against the Swift reference output.
 *
 * `ContextEncoder` exists four times, and drift between the ports would be silent: grounding would
 * simply behave slightly differently here, and the near-miss numbers measured on macOS would stop
 * describing what an Android user gets. Nothing else in the project would notice.
 *
 * The fixtures and expected output are the same files the Swift and C# suites read
 * (`eval/conformance/`), not a copy — three copies of a contract drift apart on their own.
 * Regenerate deliberately with `swift run dnt-eval conformance --write`.
 */
class ConformanceTest {
    private fun conformanceDir(): File? {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        repeat(8) {
            val candidate = File(dir, "eval/conformance/contexts.json")
            if (candidate.isFile) return candidate.parentFile
            dir = dir?.parentFile
        }
        return null
    }

    private fun JSONObject.stringOrNull(key: String): String? =
        if (isNull(key)) null else optString(key).takeIf { it.isNotEmpty() }

    private fun context(json: JSONObject): ScreenContext {
        val visible = json.optJSONObject("visibleTextRepeat")?.let { spec ->
            val line = spec.getString("line")
            (1..spec.getInt("count")).joinToString("") { line.replace("%d", it.toString()) }
        } ?: json.stringOrNull("visibleText")

        return ScreenContext(
            appName = json.stringOrNull("appName"),
            windowTitle = json.stringOrNull("windowTitle"),
            browserUrl = json.stringOrNull("browserUrl"),
            role = json.stringOrNull("role"),
            isEditable = if (json.isNull("isEditable")) null else json.optBoolean("isEditable"),
            visibleText = visible,
            textBeforeCaret = json.stringOrNull("textBeforeCaret"),
            textAfterCaret = json.stringOrNull("textAfterCaret"),
            selectedText = json.stringOrNull("selectedText"),
            screenshotPng = json.stringOrNull("screenshotBase64")
                ?.let { Base64.getDecoder().decode(it) },
        )
    }

    @Test
    fun `encoder matches the swift reference output`() {
        val dir = conformanceDir()
        assumeTrue("eval/conformance not reachable from ${System.getProperty("user.dir")}", dir != null)

        val cases = JSONArray(File(dir, "contexts.json").readText())
        val golden = JSONArray(File(dir, "golden.json").readText())
        assertEquals("fixture and golden are out of step", cases.length(), golden.length())

        for (index in 0 until cases.length()) {
            val fixture = cases.getJSONObject(index)
            val expected = golden.getJSONObject(index)
            val id = expected.getString("id")
            assertEquals("cases are compared positionally", fixture.getString("id"), id)

            val produced = ContextEncoder().encode(context(fixture))
            val expectedParts = expected.getJSONArray("parts")
            val why = expected.getString("why")
            val hint =
                "$id: $why\nIf this change was intended, regenerate with " +
                    "`swift run dnt-eval conformance --write` and re-run every port's suite."

            assertEquals("$hint\npart count", expectedParts.length(), produced.size)

            for (partIndex in produced.indices) {
                val want = expectedParts.getJSONObject(partIndex)
                when (val part = produced[partIndex]) {
                    is InputPart.Text -> {
                        assertEquals("$hint\npart $partIndex type", "text", want.getString("type"))
                        assertEquals("$hint\npart $partIndex text", want.getString("text"), part.text)
                    }
                    is InputPart.Image -> {
                        assertEquals("$hint\npart $partIndex type", "image", want.getString("type"))
                        assertEquals("$hint\npart $partIndex mime", want.getString("mimeType"), part.mimeType)
                        assertEquals("$hint\npart $partIndex bytes", want.getInt("bytes"), part.data.size)
                    }
                    else -> throw AssertionError("$hint\nunexpected part type at $partIndex")
                }
            }
        }
    }

    /**
     * The rules a port is most likely to get wrong, read off the golden file so this doubles as a
     * specification rather than restating the implementation.
     */
    @Test
    fun `port follows the rules the golden file encodes`() {
        val dir = conformanceDir()
        assumeTrue(dir != null)

        val cases = JSONArray(File(dir, "contexts.json").readText())
        fun encode(id: String): List<InputPart> {
            for (index in 0 until cases.length()) {
                val fixture = cases.getJSONObject(index)
                if (fixture.getString("id") == id) return ContextEncoder().encode(context(fixture))
            }
            throw AssertionError("no fixture $id")
        }
        fun text(part: InputPart) = (part as InputPart.Text).text

        // Nothing worth sending produces no parts at all, not an empty header.
        assertTrue(encode("12-empty").isEmpty())

        // Thin accessibility text is dropped without a screenshot and kept with one.
        assertTrue(!text(encode("05-thin-text-no-screenshot")[1]).contains("VISIBLE TEXT"))
        val withShot = encode("06-thin-text-with-screenshot")
        assertTrue("the image sits between the two text parts", withShot[1] is InputPart.Image)
        assertTrue(text(withShot[2]).contains("VISIBLE TEXT"))

        // Clipping keeps the tail: the end of a buffer is the part nearest the caret.
        val long = text(encode("11-long-visible-text")[1])
        assertTrue("the tail must survive", long.contains("line 400:"))
        assertTrue("the head is what gets dropped", !long.contains("line 1:"))

        // Whitespace is not content.
        val blank = encode("10-whitespace-only-fields")
        assertTrue(!text(blank[0]).contains("URL:"))
        assertTrue(!text(blank[1]).contains("SELECTED TEXT"))
    }
}
