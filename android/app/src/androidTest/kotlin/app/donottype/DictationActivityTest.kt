package app.donottype

import android.view.View
import android.view.ViewGroup
import android.widget.ScrollView
import android.widget.TextView
import app.donottype.core.AudioLevelMeter
import app.donottype.core.LiveMode
import app.donottype.ui.LevelMeterView
import app.donottype.ui.RecordButtonView
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Drives the app's own dictation screen, which is the screen the app now opens on.
 *
 * Before this screen existed, launching DoNotType landed on Settings: the app's headline feature
 * was reachable only from inside another app's text field, and the first thing a new user saw was
 * a form. What is asserted here is the part of that which can silently come back -- that the
 * screen builds its record button, that the button is refused rather than dead when there is no
 * key, and that the level meter is reserved rather than inserted.
 *
 * Deliberately no Espresso, for the reasons [SettingsActivityTest] gives: every assertion is about
 * what the layout built and what the app persisted, and routing that through a framework which
 * additionally requires a particular screen height and a focused window only adds ways for the
 * harness to fail instead of the code.
 */
@RunWith(AndroidJUnit4::class)
@LargeTest
class DictationActivityTest {

    /**
     * With no key the button is disabled and the screen says where to get one.
     *
     * The two halves are one assertion. "Tap to dictate" is an instruction that cannot be
     * followed without a key, so the idle line is replaced by the link that fixes it rather than
     * having the link appear underneath it -- and a disabled button with no explanation beside it
     * is the failure mode this replaces.
     */
    @Test
    fun withNoKeyTheRecordButtonIsRefusedAndTheScreenSaysWhy() {
        withNoKey {
            ActivityScenario.launch(DictationActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    val root = activity.content()
                    val button = root.firstDescendant(RecordButtonView::class.java) { true }
                    assertTrue("no key means nothing to record with", !button.isEnabled)

                    val link = root.firstDescendant(TextView::class.java) {
                        it.contentDescription == "configure-api-key"
                    }
                    assertEquals(
                        "the way to fix it has to be visible, not merely present",
                        View.VISIBLE, link.visibility)
                }
            }
        }
    }

    @Test
    fun withAKeyTheRecordButtonIsReadyAndTheLinkIsGone() {
        withKey("k-dictation-test") {
            ActivityScenario.launch(DictationActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    val root = activity.content()
                    val button = root.firstDescendant(RecordButtonView::class.java) { true }
                    assertTrue("a key is all the button needs", button.isEnabled)
                    assertEquals(RecordButtonView.Look.READY, button.look)
                    assertEquals(
                        "the button is what a screen reader announces, so it has to be named",
                        "Dictate", button.contentDescription)

                    val link = root.firstDescendant(TextView::class.java) {
                        it.contentDescription == "configure-api-key"
                    }
                    assertEquals(View.GONE, link.visibility)
                }
            }
        }
    }

    /**
     * The meter is laid out at full size while invisible.
     *
     * Reserved rather than inserted, because a meter that appeared with the first word would push
     * the button out from under the thumb that is holding it. That is only observable as a
     * measured height with zero alpha, which needs a real window -- so it is asserted here rather
     * than in a unit test.
     */
    @Test
    fun theLevelMeterIsReservedRatherThanInserted() {
        withKey("k-dictation-test") {
            ActivityScenario.launch(DictationActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    val meter = activity.content()
                        .firstDescendant(LevelMeterView::class.java) { true }
                    assertEquals("invisible at rest", 0f, meter.alpha, 0f)
                    assertTrue("but occupying its space", meter.height > 0)
                }
            }
        }
    }

    /**
     * The bars and the button's ring are driven from one buffer.
     *
     * They used to be two: the keyboard drew its own and this screen drew another, which is two
     * verdicts on the same audio. The meter is the evidence a user reads to tell a dead microphone
     * from a quiet room, so what is checked is that a fed bar reaches both the meter and the value
     * the button pulses with.
     */
    @Test
    fun feedingTheMeterMovesTheButtonsRing() {
        withKey("k-dictation-test") {
            ActivityScenario.launch(DictationActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    val meter = activity.content()
                        .firstDescendant(LevelMeterView::class.java) { true }
                    val silent = meter.newestLevel

                    meter.appendLevels(listOf(AudioLevelMeter.Bar(level = 0.8, isClipping = false)))
                    assertNotEquals(
                        "a bar the microphone produced has to reach the drawing",
                        silent, meter.newestLevel)

                    meter.clearLevels()
                    assertEquals(
                        "and clearing has to return it to silence, not to the last recording",
                        silent, meter.newestLevel, 0.0001f)
                }
            }
        }
    }

    /** Edge to edge is opt-out on Android 15, so every screen needs its own inset listener. */
    @Test
    fun contentIsKeptOutFromUnderTheSystemBars() {
        withKey("k-dictation-test") {
            ActivityScenario.launch(DictationActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    // Padded on the root rather than on the scroll view inside it, because the
                    // toolbar above the scroll view has to clear the status bar too.
                    val root = activity.findViewById<ViewGroup>(android.R.id.content)
                        .getChildAt(0) as ViewGroup
                    val bars = androidx.core.view.WindowInsetsCompat
                        .toWindowInsetsCompat(root.rootWindowInsets!!)
                        .getInsets(androidx.core.view.WindowInsetsCompat.Type.systemBars())

                    assertTrue(
                        "the device needs a status bar for this test to mean anything",
                        bars.top > 0)
                    assertEquals(
                        "the toolbar must clear the status bar", bars.top, root.paddingTop)
                    assertEquals(
                        "and the content must clear the navigation bar",
                        bars.bottom, root.paddingBottom)
                    assertTrue(
                        "the latest transcript still has to be scrollable to",
                        root.firstDescendant(ScrollView::class.java) { true }.isFillViewport)
                }
            }
        }
    }

    /**
     * The three modes are one control, and a mode that cannot run is refused rather than stored.
     *
     * The bug this replaces: the chip was a two-state Dictate/Rewrite toggle while a target
     * language in Settings quietly overrode it, so the screen could show `Rewrite` over a
     * dictation that came back translated. Translate with no language configured is the case that
     * used to be unrepresentable, so it is the one asserted on.
     */
    @Test
    fun theModeSegmentsOfferThreeAndRefuseOneThatCannotRun() {
        withKey("k-mode-test") {
            val language = Settings.translateTo
            Settings.translateTo = ""
            Settings.liveMode = LiveMode.DICTATE
            try {
                ActivityScenario.launch(DictationActivity::class.java).use { scenario ->
                    scenario.onActivity { activity ->
                        val root = activity.content()
                        val segments = listOf("mode-dictate", "mode-rewrite", "mode-translate")
                            .map { name ->
                                root.firstDescendant(TextView::class.java) {
                                    it.contentDescription == name
                                }
                            }
                        assertEquals(
                            listOf(
                                LiveMode.DICTATE.label,
                                LiveMode.REWRITE.label,
                                LiveMode.TRANSLATE.label,
                            ),
                            segments.map { it.text.toString() },
                        )

                        val translate = segments[2]
                        assertTrue(
                            "with no target language there is nothing to translate into",
                            !translate.isEnabled,
                        )
                        translate.performClick()
                        assertEquals(
                            "a mode that cannot run must not become the stored one",
                            LiveMode.DICTATE,
                            Settings.liveMode,
                        )

                        segments[1].performClick()
                        assertEquals(LiveMode.REWRITE, Settings.liveMode)
                    }
                }
            } finally {
                Settings.translateTo = language
                Settings.liveMode = LiveMode.DICTATE
            }
        }
    }

    // MARK: - Helpers

    private fun androidx.appcompat.app.AppCompatActivity.content(): ViewGroup =
        findViewById(android.R.id.content)

    /**
     * Runs [body] with a key set, and puts the key back to whatever it was afterwards.
     *
     * Restored rather than cleared, because these tests share a process with the settings suite
     * and a key left behind changes what the next test's screen builds.
     */
    private fun withKey(key: String, body: () -> Unit) = withApiKey(key, body)

    private fun withNoKey(body: () -> Unit) = withApiKey(null, body)

    private fun withApiKey(key: String?, body: () -> Unit) {
        ActivityScenario.launch(SettingsActivity::class.java).use {
            it.onActivity { Settings.apiKey = key }
        }
        try {
            body()
        } finally {
            ActivityScenario.launch(SettingsActivity::class.java).use {
                it.onActivity { Settings.apiKey = null }
            }
        }
    }

    /**
     * Breadth-first over the real hierarchy. These screens are built in code with no ids, so the
     * walk is what stands in for `findViewById` -- and driving the actual widgets keeps the
     * assertion about the app's wiring rather than about whether a given emulator is tall enough
     * to show the row.
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
}
