package app.donottype.accessibility

import app.donottype.Settings
import app.donottype.core.ScreenContext
import app.donottype.core.TokenBudget
import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Reads on-screen text for grounding.
 *
 * Android's equivalent of the macOS AXUIElement walk, and structurally simpler: the node tree is
 * already flattened per window and there is no equivalent of `AXEnhancedUserInterface` to coax
 * apps into exposing it.
 *
 * The service holds no state between dictations and stores nothing. It exists so the IME — which
 * cannot see other apps' content itself — can ask for the current screen at the moment the user
 * starts speaking.
 */
class ScreenReaderService : AccessibilityService() {

    companion object {
        /**
         * The running instance, or null when the user has not enabled the service.
         *
         * A static handle is the conventional way for an IME to reach its own AccessibilityService:
         * they are separate components in the same process, and there is no binder between them.
         */
        @Volatile
        var instance: ScreenReaderService? = null
            private set

        private const val VISIBLE_TEXT_CHARS = 10_000
        private const val CARET_WINDOW_CHARS = 1_000
        private const val MAX_NODES = 4_000
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    // Grounding is pull-based: nothing is collected until a dictation asks for it, so there is no
    // background stream of screen contents to leak or retain.
    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    /**
     * Snapshots the current screen.
     *
     * Returns an empty context when the foreground app is blocked, so the caller cannot
     * accidentally use partially-filtered content.
     */
    fun capture(): ScreenContext {
        val root = rootInActiveWindow ?: return ScreenContext()
        val packageName = root.packageName?.toString()

        if (Settings.isBlocked(packageName)) return ScreenContext()

        val collected = StringBuilder()
        var focused: AccessibilityNodeInfo? = null
        var nodes = 0

        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.addLast(root)

        while (stack.isNotEmpty() && collected.length < VISIBLE_TEXT_CHARS && nodes < MAX_NODES) {
            val node = stack.removeLast()
            nodes++

            // Custom password widgets can expose rendered characters through child nodes, so the
            // protected control is an opaque subtree rather than merely a value we do not append.
            if (node.isPassword) continue
            if (node.isFocused && node.isEditable) focused = node

            if (node.isVisibleToUser) {
                appendIfUseful(collected, node.text?.toString())
                appendIfUseful(collected, node.contentDescription?.toString())
            }
            for (i in 0 until node.childCount) {
                node.getChild(i)?.let(stack::addLast)
            }
        }

        val (before, after) = focused?.let(::caretWindow) ?: (null to null)

        return ScreenContext(
            appName = appLabel(packageName),
            windowTitle = root.text?.toString(),
            browserUrl = findBrowserUrl(root),
            role = focused?.className?.toString(),
            isEditable = focused != null,
            visibleText = TokenBudget.clipKeepingTail(collected.toString(), VISIBLE_TEXT_CHARS),
            textBeforeCaret = before,
            textAfterCaret = after,
            selectedText = selectedText(focused),
        )
    }

    private fun appendIfUseful(into: StringBuilder, text: String?) {
        val trimmed = text?.trim() ?: return
        // Single characters are almost always chrome: separators, icon labels, badge counts.
        if (trimmed.length <= 1) return
        if (into.isNotEmpty()) into.append('\n')
        into.append(trimmed)
    }

    private fun caretWindow(node: AccessibilityNodeInfo): Pair<String?, String?> {
        val value = node.text?.toString() ?: return null to null
        val caret = node.textSelectionStart.takeIf { it >= 0 } ?: value.length
        val end = node.textSelectionEnd.takeIf { it >= caret } ?: caret

        return TokenBudget.clipKeepingTail(value.substring(0, caret.coerceAtMost(value.length)), CARET_WINDOW_CHARS) to
            TokenBudget.clipKeepingHead(value.substring(end.coerceAtMost(value.length)), CARET_WINDOW_CHARS)
    }

    private fun selectedText(node: AccessibilityNodeInfo?): String? {
        val value = node?.text?.toString() ?: return null
        val start = node.textSelectionStart
        val end = node.textSelectionEnd
        if (start < 0 || end <= start || end > value.length) return null
        return value.substring(start, end)
    }

    /** Browsers expose the address bar as an editable node carrying the URL. */
    private fun findBrowserUrl(root: AccessibilityNodeInfo): String? {
        val candidates = listOf(
            "com.android.chrome:id/url_bar",
            "org.mozilla.firefox:id/mozac_browser_toolbar_url_view",
            "com.microsoft.emmx:id/url_bar",
        )
        for (id in candidates) {
            val node = root.findAccessibilityNodeInfosByViewId(id)?.firstOrNull() ?: continue
            val text = node.text?.toString()?.trim()
            if (!text.isNullOrEmpty()) return text
        }
        return null
    }

    private fun appLabel(packageName: String?): String? {
        val name = packageName ?: return null
        return runCatching {
            val info = packageManager.getApplicationInfo(name, 0)
            packageManager.getApplicationLabel(info).toString()
        }.getOrDefault(name)
    }
}
