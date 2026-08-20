package app.donottype

import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.ScrollView
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Drives the first-launch flow, which is the one screen most users see exactly once.
 *
 * That is what makes it worth an instrumentation test: a flow shown once cannot be caught by
 * anybody dogfooding the app, because they have already passed it and the flag that records so is
 * written on the way out. The gate is the specific thing this asserts -- both halves of it, since
 * either half alone is a bug with a plausible-looking implementation:
 *
 * - the flag alone would show the flow forever to someone whose key arrived by QR import
 * - the key alone would show it again to anyone who cleared their key to switch providers
 *
 * Deliberately no Espresso, for the reasons [SettingsActivityTest] gives.
 */
@RunWith(AndroidJUnit4::class)
@LargeTest
class OnboardingActivityTest {

    /**
     * The state the gate reads, saved before each test and put back after.
     *
     * The suite shares a process with the app's real preferences, so a test that leaves the flag
     * set has decided for every test after it that setup is done.
     */
    private var savedKey: String? = null
    private var savedFlag = false

    @Before
    fun saveGateState() {
        onSettings { activity ->
            Settings.initialise(activity)
            savedKey = Settings.apiKey
            savedFlag = Settings.didCompleteInitialSetup
        }
    }

    @After
    fun restoreGateState() {
        onSettings {
            Settings.apiKey = savedKey
            Settings.didCompleteInitialSetup = savedFlag
        }
    }

    @Test
    fun theFlowIsNeededOnlyBeforeItHasBeenSeenAndOnlyWithoutAKey() {
        onSettings {
            Settings.apiKey = null
            Settings.didCompleteInitialSetup = false
            assertTrue("a fresh install has nothing to dictate with", OnboardingActivity.isNeeded())

            // Mirrors an imported profile: the key arrived without the flow being walked, and
            // showing the flow anyway would be the app disagreeing with a user who is already set
            // up.
            Settings.apiKey = "k-imported"
            assertTrue(
                "a key is a completed setup however it arrived", !OnboardingActivity.isNeeded())

            // And mirrors switching providers: the key is cleared deliberately, by somebody who
            // has seen this flow and does not need it again.
            Settings.apiKey = null
            Settings.didCompleteInitialSetup = true
            assertTrue(
                "a cleared key must not reopen a flow already walked",
                !OnboardingActivity.isNeeded())
        }
    }

    /** However it is left, leaving is remembered — or the flow reappears on the next launch. */
    @Test
    fun leavingTheFlowByAnyRouteCountsAsHavingSeenIt() {
        onSettings {
            Settings.apiKey = null
            Settings.didCompleteInitialSetup = false
        }
        // Skip rather than Finish, which is the route that has to work without a key: Finish is
        // disabled until there is one, so if only Finish recorded the flag, anybody who left
        // without a key would be shown the whole flow again on every launch.
        ActivityScenario.launch(OnboardingActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.content().firstDescendant(Button::class.java) {
                    it.contentDescription == "skip-initial-setup"
                }.performClick()
            }
        }
        onSettings {
            assertTrue(
                "skipping is a decision, and the app has to remember it",
                Settings.didCompleteInitialSetup)
        }
    }

    /**
     * The transfer offer comes before the form it fills in.
     *
     * Someone who already runs DoNotType elsewhere can complete the whole provider section with
     * one scan, and should not have to read past a form they are about to overwrite. Asserted as
     * position on screen, which is the only place that ordering exists -- the screen is built in
     * code, so there is no layout file to read it off.
     */
    @Test
    fun theTransferOfferComesBeforeTheProviderForm() {
        ActivityScenario.launch(OnboardingActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val root = activity.content()
                val scan = root.firstDescendant(View::class.java) {
                    it.contentDescription == "setup-scan-settings-qr"
                }
                val key = root.firstDescendant(EditText::class.java) {
                    it.inputType and InputType.TYPE_TEXT_VARIATION_PASSWORD != 0
                }
                val scanTop = IntArray(2).also { scan.getLocationInWindow(it) }[1]
                val keyTop = IntArray(2).also { key.getLocationInWindow(it) }[1]
                assertTrue(
                    "scanning an existing profile has to be offered above the form it fills",
                    scanTop < keyTop)
            }
        }
    }

    /**
     * Every step is tappable and does the thing it names.
     *
     * A checklist of read-only ticks reports a problem and hides its solution: a row that says
     * "not done" and leaves the user to find the switch in Android's settings has told them about
     * the work without doing any of it.
     */
    @Test
    fun everyPermissionStepIsTappable() {
        ActivityScenario.launch(OnboardingActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val root = activity.content()
                for (title in listOf(
                    "Allow microphone access", "Add the DoNotType keyboard",
                    "Enable screen grounding",
                )) {
                    val row = root.firstDescendant(View::class.java) {
                        it.contentDescription == title
                    }
                    assertTrue("$title should be tappable, not a read-only tick", row.isClickable)
                }
            }
        }
    }

    /**
     * Finish is gated on a key; the connection test is too.
     *
     * The same rule as iOS's "Finish Setup": without a key there is nothing to finish, and the two
     * permissions are grantable later from a screen that says so. Testing a connection with no key
     * would send a request that can only fail.
     */
    @Test
    fun finishAndTestConnectionWaitForAKey() {
        onSettings { Settings.apiKey = null }
        ActivityScenario.launch(OnboardingActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val root = activity.content()
                val finish = root.firstDescendant(Button::class.java) {
                    it.contentDescription == "finish-initial-setup"
                }
                assertTrue("nothing to finish without a key", !finish.isEnabled)
                val test = root.firstDescendant(Button::class.java) {
                    it.text.toString() == "Test connection"
                }
                assertTrue("and nothing to test", !test.isEnabled)

                // Saved as it is typed rather than behind a Save button: there is no other screen
                // to carry the value to, and a flow whose Finish is enabled only after pressing a
                // different button first is the shape of a form people abandon.
                root.firstDescendant(EditText::class.java) {
                    it.contentDescription == "setup-api-key"
                }.setText("k-onboarding-test")
            }
            scenario.onActivity { activity ->
                assertEquals("k-onboarding-test", Settings.apiKey)
                val finish = activity.content().firstDescendant(Button::class.java) {
                    it.contentDescription == "finish-initial-setup"
                }
                assertTrue("a key is all Finish was waiting for", finish.isEnabled)
            }
        }
    }

    /** Edge to edge is opt-out on Android 15, and this is the first screen a user ever sees. */
    @Test
    fun contentIsKeptOutFromUnderTheSystemBars() {
        ActivityScenario.launch(OnboardingActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val root = activity.findViewById<ViewGroup>(android.R.id.content)
                    .getChildAt(0) as ScrollView
                val bars = WindowInsetsCompat
                    .toWindowInsetsCompat(root.rootWindowInsets!!)
                    .getInsets(WindowInsetsCompat.Type.systemBars())

                assertTrue(
                    "the device needs a status bar for this test to mean anything", bars.top > 0)
                assertEquals(
                    "the scroll viewport should be inset, not the column in it",
                    bars.top, root.paddingTop)
                assertTrue(
                    "clipToPadding must stay on, or scrolled rows run under the bars",
                    root.clipToPadding)
            }
        }
    }

    // MARK: - Helpers

    /**
     * Reads or writes settings on the main thread with an initialised store, without launching the
     * screen under test. Goes through Settings rather than through the onboarding screen, because
     * half of these tests are about what the app decides *before* that screen exists.
     */
    private fun onSettings(body: (SettingsActivity) -> Unit) {
        ActivityScenario.launch(SettingsActivity::class.java).use { it.onActivity(body) }
    }

    private fun androidx.appcompat.app.AppCompatActivity.content(): ViewGroup =
        findViewById(android.R.id.content)

    /** Breadth-first over the real hierarchy; see [SettingsActivityTest] for why. */
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
}
