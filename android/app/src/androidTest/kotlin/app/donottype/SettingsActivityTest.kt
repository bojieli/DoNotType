package app.donottype

import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.ScrollView
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.isEnabled
import androidx.test.espresso.matcher.ViewMatchers.withText
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
        ActivityScenario.launch(SettingsActivity::class.java).use {
            // Existence in the hierarchy rather than `scrollTo()` plus `isDisplayed()`. Espresso's
            // scroll action additionally demands the view end up 90% visible, which depends on how
            // tall the device is -- these passed on a phone-sized emulator and failed on CI's.
            // What is being asserted is that the layout builds every setup action and leaves it
            // usable, and that does not need a particular screen height to be true.
            for (label in listOf(
                "Grant microphone access", "Enable the keyboard",
                "Enable screen grounding (optional)", "Save", "Test connection",
            )) {
                onView(withText(label)).check(matches(isEnabled()))
            }
        }
    }

    /** The setting without which the app can do nothing at all. */
    @Test
    fun savingAnApiKeyPersistsIt() {
        ActivityScenario.launch(SettingsActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val root = activity.findViewById<ViewGroup>(android.R.id.content)
                val field = root.firstDescendant(EditText::class.java) { it.hint == "Gemini API key" }
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

    /** The contract is the product; the app claims you can read and edit it in place. */
    @Test
    fun theShippedPromptIsReadableInTheApp() {
        ActivityScenario.launch(SettingsActivity::class.java).use { scenario ->
            scenario.onActivity {
                val prompt = PromptAssets.activeTemplate(it)
                assertTrue(
                    "the prompt editor should be populated from the bundled PROMPT.md",
                    prompt.contains("SPELLING"))
            }
        }
    }
}
