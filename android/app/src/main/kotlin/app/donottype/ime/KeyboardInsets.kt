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
     * @param basePadding the bar's own trailing padding, which is kept whatever the bars do — a row
     *   of keys flush against the bottom of the screen is unpleasant to hit even with nothing
     *   drawn over it.
     * @param dispatchedNavigationInset the navigation-bar inset delivered to the input view.
     * @param windowNavigationInset the navigation-bar inset the display reports for this window,
     *   which is available whether or not a dispatch has happened.
     */
    fun bottomPadding(
        basePadding: Int,
        dispatchedNavigationInset: Int,
        windowNavigationInset: Int,
        sdkInt: Int = Build.VERSION.SDK_INT,
    ): Int {
        val navigationBar = if (sdkInt >= EDGE_TO_EDGE_SDK) {
            maxOf(dispatchedNavigationInset, windowNavigationInset)
        } else {
            // The window sits above the bar here. Honour a dispatched inset if one arrives — a
            // device that reports one is telling us it does overlap — but never invent one.
            dispatchedNavigationInset
        }
        return maxOf(basePadding, 0) + maxOf(navigationBar, 0)
    }
}
