package app.donottype

import android.view.ViewGroup
import android.widget.ScrollView
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.clearText
import androidx.test.espresso.action.ViewActions.closeSoftKeyboard
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.action.ViewActions.scrollTo
import androidx.test.espresso.action.ViewActions.typeText
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withHint
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
    fun everySetupActionIsOnScreen() {
        ActivityScenario.launch(SettingsActivity::class.java).use {
            for (label in listOf(
                "Grant microphone access", "Enable the keyboard",
                "Enable screen grounding (optional)", "Save", "Test connection",
            )) {
                onView(withText(label)).perform(scrollTo()).check(matches(isDisplayed()))
            }
        }
    }

    /** The setting without which the app can do nothing at all. */
    @Test
    fun savingAnApiKeyPersistsIt() {
        ActivityScenario.launch(SettingsActivity::class.java).use { scenario ->
            onView(withHint("Gemini API key")).perform(scrollTo(), clearText(), typeText("k-123"))
            closeSoftKeyboard()
            onView(withText("Save")).perform(scrollTo(), click())

            scenario.onActivity { assertEquals("k-123", Settings.apiKey) }
        }
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
