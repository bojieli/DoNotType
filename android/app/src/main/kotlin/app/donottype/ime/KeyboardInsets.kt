package app.donottype.ime

import android.os.Build

/**
 * How much room the keyboard has to keep clear at its bottom edge.
 *
 * Pure arithmetic, in its own file, because the bug it exists to stop is invisible on a developer
 * machine and expensive on a phone: the bottom row of keys sitting underneath the navigation bar,
 * where half of every key is a system button. There is no emulator assertion for "the user cannot
 * press this", so the decision is made here where a JVM test can check it.
 *
 * Two facts drive it:
 *
 * 1. **From API 35 an IME window is laid out behind the navigation bar.** Below that the window
 *    manager places the keyboard above the bar and reports no bottom inset, so padding added from
 *    a display-level measurement would be a dead strip on every older phone.
 * 2. **The inset dispatched to the input view is not always the one that matters.** An
 *    `OnApplyWindowInsetsListener` installed on a view that is added to a window which is already
 *    laid out may not be called until something else asks for a dispatch, and a listener that has
 *    not run leaves the padding at zero. The keyboard asks for one on every show, and takes the
 *    display's own navigation inset as the floor when the window is edge to edge, so a missed
 *    dispatch costs nothing.
 */
object KeyboardInsets {

    /** The first API level that lays an `InputMethodService` window out behind the system bars. */
    const val EDGE_TO_EDGE_SDK: Int = 35

    /**
     * Bottom padding for the keyboard's root view.
     *
     * The navigation inset alone is not enough, and measuring said so. Gesture navigation reports
     * about 24dp — the home pill's strip — while three-button navigation reports about 48dp, so
     * padding by the inset plus a small gap left the gesture case at roughly 34dp and the
     * three-button case at 58dp. The ergonomic requirement does not vary like that: a thumb needs
     * the same room away from the bottom of the screen either way, and at 34dp the bottom row was
     * reported as still too low to hit comfortably. Gboard, measured on the same screen, leaves
     * about 62dp below its bottom key row, and that is what the floor is set from.
     *
     * So the answer is a floor rather than a sum: never closer to the bottom of the screen than
     * [minimumClearance], and never closer to the navigation bar than [basePadding].
     *
     * @param basePadding the gap kept above the navigation bar itself.
     * @param minimumClearance the least room allowed between the last row and the bottom of the
     *   screen, which is what the gesture-navigation case needs.
     * @param dispatchedNavigationInset the navigation-bar inset delivered to the input view.
     * @param windowNavigationInset the navigation-bar inset the display reports for this window,
     *   which is available whether or not a dispatch has happened.
     */
    fun bottomPadding(
        basePadding: Int,
        minimumClearance: Int,
        dispatchedNavigationInset: Int,
        windowNavigationInset: Int,
        sdkInt: Int = Build.VERSION.SDK_INT,
    ): Int {
        val base = maxOf(basePadding, 0)
        if (sdkInt < EDGE_TO_EDGE_SDK) {
            // The window sits above the bar here, so the strip this clearance protects against is
            // outside it entirely and a floor would be that many dp of dead keyboard. Honour a
            // dispatched inset if one arrives — a device that reports one is telling us it does
            // overlap — but never invent one.
            return base + maxOf(dispatchedNavigationInset, 0)
        }
        val navigationBar =
            maxOf(maxOf(dispatchedNavigationInset, windowNavigationInset), 0)
        return maxOf(base + navigationBar, maxOf(minimumClearance, 0))
    }
}
