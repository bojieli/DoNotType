package app.donottype

import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.ScrollView
import android.widget.Spinner
import app.donottype.core.Fidelity
import app.donottype.core.LogRouter
import app.donottype.core.RewriteStyle
import app.donottype.core.SummaryStyle
import app.donottype.core.TranscriptMode
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Drives the settings screen on a real device or emulator.
 *
 * The unit tests cover the core and never open a window, so nothing caught that on Android 15 this
 * screen drew underneath the status bar: the heading was half hidden behind the clock and scrolled
 * rows ran under it. Insets are only observable with a window on a screen, which is what this is.
 *
 * Deliberately no Espresso. Every assertion here is about the app -- what the layout built, what it
 * persisted -- and routing those through a framework that additionally requires a particular screen
 * height and a focused window only adds ways for the harness to fail instead of the code.
 */
@RunWith(AndroidJUnit4::class)
@LargeTest
class SettingsActivityTest {

    @Before
    fun clearKey() {
        ActivityScenario.launch(SettingsActivity::class.java).use {
            it.onActivity { Settings.apiKey = null }
        }
    }

    /**
     * The regression test for the edge-to-edge bug. Android 15 hands every app the area behind the
     * system bars whether it asked for it or not; a layout built in code gets no insets applied
     * for it, so without an explicit listener the content starts at y=0, behind the clock.
     *
     * The padding has to be on the scroll view rather than on the column inside it: padding the
     * column fixes only the resting position, and scrolling still runs text under the status bar.
     */
    @Test
    fun contentIsKeptOutFromUnderTheSystemBars() {
        ActivityScenario.launch(SettingsActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val root = activity.findViewById<ViewGroup>(android.R.id.content)
                    .getChildAt(0) as ScrollView

                val bars = WindowInsetsCompat
                    .toWindowInsetsCompat(root.rootWindowInsets!!)
                    .getInsets(WindowInsetsCompat.Type.systemBars())

                assertTrue(
                    "the device needs a status bar for this test to mean anything",
                    bars.top > 0)
                assertEquals(
                    "the scroll viewport should be inset by the status bar, not the column in it",
                    bars.top, root.paddingTop)
                assertEquals(
                    "and by the navigation bar at the bottom",
                    bars.bottom, root.paddingBottom)
                assertTrue(
                    "clipToPadding must stay on, or scrolled rows run under the bars",
                    root.clipToPadding)
            }
        }
    }

    @Test
    fun everySetupActionIsBuilt() {
        ActivityScenario.launch(SettingsActivity::class.java).use { scenario ->
            // Walks the hierarchy rather than going through Espresso. Espresso first demanded the
            // view end up 90% visible, which depends on how tall the device is, and then demanded
            // the window have focus, which a headless CI emulator does not reliably give it --
            // both are facts about the harness rather than about the app. What is being asserted
            // is that the layout builds every setup action and leaves it usable, and neither the
            // height of the screen nor which window the emulator focused changes that.
            scenario.onActivity { activity ->
                val root = activity.findViewById<ViewGroup>(android.R.id.content)
                for (label in listOf(
                    "Grant microphone access", "Enable the keyboard",
                    "Enable screen grounding (optional)", "Save", "Test connection",
                )) {
                    val button = root.firstDescendant(Button::class.java) {
                        it.text.toString() == label
                    }
                    assertTrue("$label should be enabled", button.isEnabled)
                }
            }
        }
    }

    /** The setting without which the app can do nothing at all. */
    @Test
    fun savingAnApiKeyPersistsIt() {
        ActivityScenario.launch(SettingsActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val root = activity.findViewById<ViewGroup>(android.R.id.content)
                // Matched on being the password field rather than on its hint. The hint is prose
                // and prose gets rewritten -- it has already changed from "Gemini API key" to
                // "API key" now that there is more than one provider -- whereas the key field is
                // the only masked input on the screen and that is what makes it the key field.
                val field = root.firstDescendant(EditText::class.java) {
                    it.inputType and InputType.TYPE_TEXT_VARIATION_PASSWORD != 0
                }
                val save = root.firstDescendant(Button::class.java) { it.text.toString() == "Save" }

                field.setText("k-123")
                save.performClick()
            }
            scenario.onActivity { assertEquals("k-123", Settings.apiKey) }
        }
    }

    /**
     * Breadth-first over the real hierarchy. The screen is built in code with no ids, and driving
     * the actual widgets keeps the assertion about the app's wiring rather than about whether a
     * given emulator is tall enough to show the row.
     *
     * Takes a `Class` rather than being `reified`, because an inline function cannot recurse and
     * a walk of a view tree has to.
     */
    private fun <T : View> View.firstDescendant(type: Class<T>, predicate: (T) -> Boolean): T {
        val queue = ArrayDeque<View>().apply { add(this@firstDescendant) }
        while (queue.isNotEmpty()) {
            val view = queue.removeFirst()
            if (type.isInstance(view) && predicate(type.cast(view)!!)) return type.cast(view)!!
            if (view is ViewGroup) {
                for (i in 0 until view.childCount) queue.add(view.getChildAt(i))
            }
        }
        throw NoSuchElementException("no ${type.simpleName} matched in the view tree")
    }

    /**
     * The two screens added for offline transcription and for reading the log.
     *
     * Nothing here can transcribe without a paid request, so what is asserted is what can silently
     * break: that both entry points are built and reachable, that the file screen offers all three
     * modes, and that the log screen is not empty — the app logs its own startup, so an empty
     * buffer there means logging never started.
     */
    @Test
    fun theOfflineAndDiagnosticScreensAreReachable() {
        ActivityScenario.launch(SettingsActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val root = activity.findViewById<ViewGroup>(android.R.id.content)
                for (label in listOf("Transcribe a recording…", "Logs")) {
                    val button = root.firstDescendant(Button::class.java) {
                        it.text.toString() == label
                    }
                    assertTrue("$label should be enabled", button.isEnabled)
                }
            }
        }

        ActivityScenario.launch(FileTranscriptionActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val root = activity.findViewById<ViewGroup>(android.R.id.content)
                val modes = root.firstDescendant(Spinner::class.java) { spinner ->
                    (0 until spinner.adapter.count)
                        .map { spinner.adapter.getItem(it).toString() }
                        .any { it.startsWith("Summary") }
                }
                val labels = (0 until modes.adapter.count).map { modes.adapter.getItem(it).toString() }
                assertEquals(
                    "the file screen should offer exactly the modes the core defines",
                    TranscriptMode.ALL.size, labels.size)
                assertTrue(labels.any { it.startsWith("Verbatim") })
                assertTrue(labels.any { it.startsWith("Rewrite") })
                assertTrue(labels.any { it.startsWith("Summary") })
            }
        }

        ActivityScenario.launch(LogsActivity::class.java).use { scenario ->
            scenario.onActivity {
                assertTrue(
                    "the app logs its own startup, so the buffer should not be empty",
                    LogRouter.recent().isNotEmpty())
            }
        }
    }

    /** The contract is the product; the app claims you can read and edit it in place. */
    @Test
    fun theShippedPromptIsReadableInTheApp() {
        ActivityScenario.launch(SettingsActivity::class.java).use { scenario ->
            scenario.onActivity {
                val prompt = PromptAssets.editableText(it, PromptPart.SYSTEM)
                assertTrue(
                    "the prompt editor should be populated from the bundled prompt/system.md",
                    prompt.contains("SPELLING"))
            }
        }
    }

    /**
     * Every part has to be in the APK, not just the one the editor opens on. A missing asset is
     * invisible until somebody picks that fidelity or style, and then it fails mid-dictation.
     */
    @Test
    fun everyPartIsBundledAndAssembles() {
        ActivityScenario.launch(SettingsActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                for (part in PromptPart.all) {
                    val text = PromptAssets.text(activity, part)
                    assertTrue("${part.relativePath} is empty", text.isNotBlank())
                    assertTrue("${part.relativePath} carries a marker", !text.contains("<!--"))
                }
                for (fidelity in Fidelity.entries) {
                    val instruction = PromptAssets.systemInstruction(activity, fidelity)
                    assertTrue(
                        "the ${fidelity.id} instruction is not the contract",
                        instruction.startsWith("You are a transcription engine."))
                    assertTrue(
                        "an unfilled placeholder reached the model",
                        !instruction.contains("{{"))
                    assertTrue(
                        "the ${fidelity.id} transcription prompt grew",
                        instruction.trim().split(Regex("\\s+")).size <= 160)
                }

                val rewrite = PromptAssets.secondStageInstruction(
                    activity, TranscriptMode.Rewrite(RewriteStyle.FORMAL))!!
                assertTrue(
                    "the default rewrite prompt grew", rewrite.split(Regex("\\s+")).size <= 100)
                for (phrase in listOf(
                    "vocal fillers", "\"um\"", "\"ah\"", "\"actually\"", "\"basically\"",
                    "concise"))
                    assertTrue("the default rewrite lost $phrase", rewrite.contains(phrase))

                val summary = PromptAssets.secondStageInstruction(
                    activity, TranscriptMode.Summary(SummaryStyle.BRIEF))!!
                assertTrue("the default summary prompt grew", summary.split(Regex("\\s+")).size <= 90)
            }
        }
    }
}
