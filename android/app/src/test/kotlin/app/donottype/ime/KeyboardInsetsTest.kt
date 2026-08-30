package app.donottype.ime

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The keyboard's bottom padding.
 *
 * These are the cases that produced the two bugs and the cases that would produce their opposites.
 * A device that reports nothing must not gain a dead strip; a device whose window is behind the
 * navigation bar must not lose its bottom row to it — including when nothing was dispatched to the
 * view, which is the state the old listener could sit in indefinitely; and gesture navigation,
 * whose inset is half of three-button's, must not end up with half the room for a thumb.
 */
class KeyboardInsetsTest {

    /** The gap kept above the navigation bar itself, in pixels at 2.625x. */
    private val base = 26

    /** 48dp of least clearance from the bottom of the screen, at the same density. */
    private val floor = 126

    /** A three-button navigation bar, at the density the complaint came from. */
    private val threeButtonBar = 126

    /** Gesture navigation's home-pill strip: half the three-button bar. */
    private val gesturePill = 63

    @Test
    fun edgeToEdgeKeepsTheBarClearOfAThreeButtonNavigation() {
        assertEquals(
            base + threeButtonBar,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                minimumClearance = floor,
                dispatchedNavigationInset = threeButtonBar,
                windowNavigationInset = threeButtonBar,
                sdkInt = 36,
            ),
        )
    }

    /**
     * The second bug, and the reason the floor exists. The pill's own inset plus a gap is 89px —
     * 34dp — which measured as still too low to hit; the floor lifts it to the 48dp a
     * three-button phone was already getting.
     */
    @Test
    fun gestureNavigationGetsTheSameRoomAsThreeButton() {
        assertEquals(
            floor,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                minimumClearance = floor,
                dispatchedNavigationInset = gesturePill,
                windowNavigationInset = gesturePill,
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
                minimumClearance = floor,
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
                minimumClearance = floor,
                dispatchedNavigationInset = threeButtonBar,
                windowNavigationInset = gesturePill,
                sdkInt = 36,
            ),
        )
    }

    /**
     * Below API 35 the window manager places the keyboard above the navigation bar, so the display's
     * inset describes something that is not overlapping this window and the floor would be that many
     * pixels of dead keyboard. Both are asserted against here.
     */
    @Test
    fun olderPlatformsIgnoreTheDisplayInsetAndTheFloor() {
        assertEquals(
            base,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                minimumClearance = floor,
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
            base + gesturePill,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                minimumClearance = floor,
                dispatchedNavigationInset = gesturePill,
                windowNavigationInset = 0,
                sdkInt = 30,
            ),
        )
    }

    /**
     * Landscape with the navigation bar on the side reports no bottom inset at all — and the floor
     * still applies, because the bottom of the screen is still the bottom of the screen.
     */
    @Test
    fun noNavigationBarBelowStillKeepsTheFloor() {
        assertEquals(
            floor,
            KeyboardInsets.bottomPadding(
                basePadding = base,
                minimumClearance = floor,
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
                minimumClearance = -5,
                dispatchedNavigationInset = -1,
                windowNavigationInset = -20,
                sdkInt = 36,
            ),
        )
    }
}
