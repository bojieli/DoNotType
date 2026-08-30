package app.donottype.ime

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The keyboard's bottom padding.
 *
 * These are the cases that produced the bug and the cases that would produce its opposite. A
 * device that reports nothing must not gain a dead strip, and a device whose window is behind the
 * navigation bar must not lose its bottom row to it — including when nothing was dispatched to the
 * view, which is the state the old listener could sit in indefinitely.
 */
class KeyboardInsetsTest {

    private val base = 10
    /** A three-button navigation bar, at the density the complaint came from. */
    private val threeButtonBar = 126

    @Test
    fun edgeToEdgeKeepsTheBarClearOfAThreeButtonNavigation() {
        assertEquals(
            base + threeButtonBar,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                dispatchedNavigationInset = threeButtonBar,
                windowNavigationInset = threeButtonBar,
                sdkInt = 36,
            ),
        )
    }

    @Test
    fun edgeToEdgeUsesTheDisplayWhenNoInsetWasDispatched() {
        assertEquals(
            base + threeButtonBar,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                dispatchedNavigationInset = 0,
                windowNavigationInset = threeButtonBar,
                sdkInt = KeyboardInsets.EDGE_TO_EDGE_SDK,
            ),
        )
    }

    @Test
    fun edgeToEdgeTakesTheLargerOfTheTwoMeasurements() {
        assertEquals(
            base + threeButtonBar,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                dispatchedNavigationInset = threeButtonBar,
                windowNavigationInset = 63,
                sdkInt = 36,
            ),
        )
    }

    /**
     * Below API 35 the window manager places the keyboard above the navigation bar, so the
     * display's inset describes something that is not overlapping this window. Adding it would put
     * a strip of dead keyboard on every older phone, which is the failure this asserts against.
     */
    @Test
    fun olderPlatformsIgnoreTheDisplayInset() {
        assertEquals(
            base,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                dispatchedNavigationInset = 0,
                windowNavigationInset = threeButtonBar,
                sdkInt = KeyboardInsets.EDGE_TO_EDGE_SDK - 1,
            ),
        )
    }

    /** A dispatched inset is a device saying its window does overlap. Honour it at any level. */
    @Test
    fun olderPlatformsStillHonourADispatchedInset() {
        assertEquals(
            base + 63,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                dispatchedNavigationInset = 63,
                windowNavigationInset = 0,
                sdkInt = 30,
            ),
        )
    }

    /** Gesture navigation: a thin pill, and the bar keeps clear of that too. */
    @Test
    fun gestureNavigationGetsItsPillsWorthOfRoom() {
        assertEquals(
            base + 63,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                dispatchedNavigationInset = 63,
                windowNavigationInset = 63,
                sdkInt = 36,
            ),
        )
    }

    /** Landscape with the navigation bar on the side reports no bottom inset at all. */
    @Test
    fun noNavigationBarBelowLeavesOnlyTheBarsOwnPadding() {
        assertEquals(
            base,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                dispatchedNavigationInset = 0,
                windowNavigationInset = 0,
                sdkInt = 36,
            ),
        )
    }

    /** Nothing a platform reports may subtract from the bar's own trailing room. */
    @Test
    fun negativeMeasurementsCannotShrinkTheBar() {
        assertEquals(
            base,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                dispatchedNavigationInset = -1,
                windowNavigationInset = -20,
                sdkInt = 36,
            ),
        )
    }
}
