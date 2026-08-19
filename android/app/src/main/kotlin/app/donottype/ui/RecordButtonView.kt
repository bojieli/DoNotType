package app.donottype.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.drawable.Drawable
import android.view.MotionEvent
import android.view.View
import androidx.appcompat.content.res.AppCompatResources
import androidx.core.graphics.ColorUtils
import app.donottype.R

/**
 * The one control the dictation screen is for.
 *
 * A drawn view rather than a styled button, for three reasons that all come from what it has to
 * show: a ring that scales with the newest microphone level, a fill that changes meaning between
 * ready and recording, and a thinking animation in place of its icon while a request is out. None
 * of those are things a MaterialButton can be talked into, and faking them with nested views would
 * cost a layout pass per audio frame.
 *
 * The gesture is the one the desktop hotkey uses, and for the same reason: hold-only forces you to
 * keep a finger down for the length of a thought, which is fine for a sentence and miserable for a
 * paragraph, while toggle-only means a mis-tap leaves the microphone open. Both are supported, and
 * recording starts on touch-down either way -- waiting to find out which gesture it is would clip
 * the first word, the one people say fastest. The timing itself belongs to
 * [app.donottype.core.DictationController]; this view only reports the touches.
 */
class RecordButtonView(context: Context) : View(context) {

    /** What the button is currently saying. Not the dictation state: the button has no notices. */
    enum class Look { READY, RECORDING, WORKING }

    var look: Look = Look.READY
        set(value) {
            if (field == value) return
            field = value
            dots.reset()
            // Only the working animation is drawn from a clock. Ready and recording redraw when
            // something actually changes, which for recording is when audio arrives.
            if (value == Look.WORKING) post(tick) else removeCallbacks(tick)
            invalidate()
        }

    /** The newest microphone level, 0-1. The ring breathes with it while recording. */
    var level: Float = 0f
        set(value) {
            if (field == value) return
            field = value
            if (look == Look.RECORDING) invalidate()
        }

    /** Touch-down, with the touch's own timestamp. See [app.donottype.core.DictationController]. */
    var onPressDown: (Long) -> Unit = {}

    /** Touch-up or a cancelled gesture, with the touch's own timestamp. */
    var onPressUp: (Boolean, Long) -> Unit = { _, _ -> }

    /**
     * A screen reader's activation, which arrives as one event rather than a press and a release.
     * Given its own hook so an assistive tap is an unambiguous start-or-stop rather than a press
     * of some accidental length.
     */
    var onActivate: () -> Unit = {}

    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(RING_STROKE_DP)
    }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val dots = ThinkingDots()

    private val micIcon: Drawable? = icon(R.drawable.ic_mic)
    private val stopIcon: Drawable? = icon(R.drawable.ic_stop)

    /** ~30 fps. Fast enough to read as motion, slow enough not to matter on battery. */
    private val tick = object : Runnable {
        override fun run() {
            dots.advance()
            invalidate()
            if (look == Look.WORKING) postDelayed(this, 33)
        }
    }

    init {
        isClickable = true
        isFocusable = true
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(tick)
        super.onDetachedFromWindow()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = context.dp(DIAMETER_DP)
        setMeasuredDimension(
            resolveSize(size, widthMeasureSpec),
            resolveSize(size, heightMeasureSpec),
        )
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled) return false
        return when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                onPressDown(event.eventTime)
                true
            }
            MotionEvent.ACTION_UP -> {
                onPressUp(false, event.eventTime)
                true
            }
            MotionEvent.ACTION_CANCEL -> {
                // A finger dragged off the button, or the system stealing the gesture. Not an end
                // the user chose, so the recording is discarded rather than sent.
                onPressUp(true, event.eventTime)
                true
            }
            else -> super.onTouchEvent(event)
        }
    }

    /**
     * Reached only by an accessibility activation: the touch handling above consumes real presses
     * without ever letting the framework detect a click, so there is no path where both fire.
     */
    override fun performClick(): Boolean {
        super.performClick()
        if (isEnabled) onActivate()
        return true
    }

    override fun onDraw(canvas: Canvas) {
        val centreX = width / 2f
        val centreY = height / 2f
        val primary = themeColor(androidx.appcompat.R.attr.colorPrimary)

        // The ring pulses with the newest bar, so the microphone is visibly live from the corner of
        // the eye that is watching the button rather than the meter.
        val pulse = if (look == Look.RECORDING) level.coerceIn(0f, 1f) else 0f
        ringPaint.color = ColorUtils.setAlphaComponent(primary, RING_ALPHA)
        canvas.drawCircle(centreX, centreY, dp(RING_RADIUS_DP) * (1 + pulse * RING_GROWTH), ringPaint)

        fillPaint.color = if (look == Look.RECORDING) {
            themeColor(androidx.appcompat.R.attr.colorError)
        } else {
            primary
        }
        canvas.drawCircle(centreX, centreY, dp(FILL_RADIUS_DP), fillPaint)

        val onFill = themeColor(
            if (look == Look.RECORDING) {
                com.google.android.material.R.attr.colorOnError
            } else {
                com.google.android.material.R.attr.colorOnPrimary
            },
        )

        if (look == Look.WORKING) {
            dotPaint.color = onFill
            dots.draw(canvas, centreX, centreY, dp(DOT_RADIUS_DP), dotPaint)
            return
        }

        val icon = (if (look == Look.RECORDING) stopIcon else micIcon) ?: return
        val half = dp(ICON_DP) / 2
        icon.setTint(onFill)
        icon.setBounds(
            (centreX - half).toInt(),
            (centreY - half).toInt(),
            (centreX + half).toInt(),
            (centreY + half).toInt(),
        )
        icon.draw(canvas)
    }

    private fun icon(id: Int): Drawable? =
        AppCompatResources.getDrawable(context, id)?.mutate()

    private fun dp(value: Int): Float = context.dp(value).toFloat()

    private fun themeColor(attr: Int): Int = context.themeColor(attr)

    private companion object {
        /**
         * Big enough for the ring at full pulse. The ring rests at [RING_RADIUS_DP], grows by
         * [RING_GROWTH] on a loud syllable and is [RING_STROKE_DP] thick, so the outermost pixel it
         * can reach is 76 * 1.22 + 5 = 98dp -- just inside this view's own half-width, which is why
         * a shout does not clip against the edge.
         */
        const val DIAMETER_DP = 200
        const val RING_RADIUS_DP = 76
        const val RING_STROKE_DP = 10
        const val FILL_RADIUS_DP = 62
        const val ICON_DP = 48
        const val DOT_RADIUS_DP = 8
        const val RING_GROWTH = 0.22f

        /** Faint enough that the ring reads as an aura rather than a second button. */
        const val RING_ALPHA = 64
    }
}
