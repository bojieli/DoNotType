package app.donottype.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.View
import androidx.core.content.ContextCompat
import app.donottype.R
import app.donottype.core.AudioLevelMeter
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sin

/**
 * The two things a dictation surface says without words: *I can hear you*, and *I am working*.
 *
 * Both drawings now exist twice over -- once on the keyboard bar, once on the app's dictation
 * screen -- so the drawing itself lives here and each surface supplies only its own paints and
 * geometry. Keeping them identical is not tidiness: the meter is the evidence a user reads to tell
 * a dead microphone from a quiet room, and two implementations that drift are two different
 * verdicts on the same audio.
 */

/**
 * The rolling window of bars, and how to draw it.
 *
 * Always full: the meter starts flat rather than growing in from the left, because an empty meter
 * and a silent one should not look different.
 */
class LevelBars(private val visible: Int = VISIBLE_BARS) {

    private val bars = MutableList(visible) { AudioLevelMeter.Bar.SILENT }
    private val rect = RectF()

    /**
     * The newest bar's height, 0-1, for anything that pulses with the voice instead of drawing it.
     * The record button's ring uses it, which is what makes the microphone visibly live from the
     * corner of the eye that is watching the button rather than the meter.
     */
    val newest: Float get() = bars.last().level.toFloat()

    /**
     * Adds however many bars the microphone has produced since the last redraw. Returns whether
     * anything arrived, so a caller can skip an invalidate that would draw the same frame again.
     */
    fun append(incoming: List<AudioLevelMeter.Bar>): Boolean {
        if (incoming.isEmpty()) return false
        val kept = incoming.takeLast(visible)
        repeat(kept.size) { bars.removeAt(0) }
        bars += kept
        return true
    }

    fun clear() {
        for (index in bars.indices) bars[index] = AudioLevelMeter.Bar.SILENT
    }

    /**
     * The last second and a half of the microphone, walking leftwards.
     *
     * What it replaced is worth saying, because it looked like this. Five bars driven by a single
     * current level -- a raw peak over a divisor -- and swayed by a travelling sine, so the level
     * sat pinned at the top through most of a normally-recorded voice and the movement was the
     * same whether the microphone was hearing a sentence or nothing at all. Here every bar is 60 ms
     * of audio that actually happened, and the meter moves because the audio does.
     *
     * @param clipped paints a bar whose audio was clamped at the rail on the way in. Not
     *   decoration: a recording distorted before any backend sees it is worth one colour, and
     *   nothing else in either app would ever mention it.
     */
    fun draw(canvas: Canvas, width: Int, height: Int, normal: Paint, clipped: Paint) {
        val gap = width / (visible * 2.6f)
        val barWidth = (width - gap * (visible - 1)) / visible
        var x = 0f

        for (bar in bars) {
            // Silence is a row of dots rather than nothing at all: a meter that disappears when the
            // room is quiet cannot be told apart from one that has stopped.
            val barHeight = max(barWidth, height * 0.8f * bar.level.toFloat())
            rect.set(x, (height - barHeight) / 2f, x + barWidth, (height + barHeight) / 2f)
            canvas.drawRoundRect(
                rect, barWidth / 2f, barWidth / 2f,
                if (bar.isClipping) clipped else normal,
            )
            x += barWidth + gap
        }
    }

    companion object {
        /**
         * How much of the recording the meter shows: 24 bars of 60 ms, so a second and a half.
         * Long enough that the sentence being spoken is on screen, short enough for the bars to
         * stay readable on a phone.
         */
        const val VISIBLE_BARS = 24
    }
}

/**
 * A dot travelling along a track, for the wait after somebody stops talking.
 *
 * Deliberately unlike the recording bars, and driven by a clock rather than by input. Once the
 * user has stopped speaking there is nothing to reflect, so the only honest message is "still
 * going" -- and the thing it has to prevent is the user concluding the app has hung and pressing
 * the button again. Two animations that merely differ in speed would not answer that at a glance.
 */
class ThinkingDots {

    private var phase = 0.0

    fun reset() {
        phase = 0.0
    }

    /** One frame on. Callers drive this from their own ticker, so each keeps its own frame rate. */
    fun advance() {
        phase += 0.10
    }

    fun draw(canvas: Canvas, centreX: Float, centreY: Float, radius: Float, paint: Paint) {
        val spacing = radius * 3.2f
        for (index in 0 until DOTS) {
            // Each dot lags the one before it, so the group reads as motion in one direction
            // rather than three things blinking.
            val local = sin(phase * 3 - index * 0.7)
            val scale = (0.55 + 0.45 * abs(local)).toFloat()
            val x = centreX + (index - (DOTS - 1) / 2f) * spacing
            paint.alpha = (140 + 115 * abs(local)).toInt().coerceIn(0, 255)
            canvas.drawCircle(x, centreY, radius * scale, paint)
        }
    }

    private companion object {
        const val DOTS = 3
    }
}

/**
 * The meter on the app's dictation screen.
 *
 * Reserved rather than inserted, by the screen that holds it: a meter that appears on the first
 * word would push the record button out from under the thumb that is holding it. So this view is
 * always laid out and the screen fades it in, which is also why it draws nothing of its own when
 * the levels are flat -- a flat row of dots is the correct picture of a live microphone in a quiet
 * room.
 *
 * Themed, unlike the keyboard's copy: this one sits on an ordinary app surface that follows the
 * system's light and dark setting.
 */
class LevelMeterView(context: Context) : View(context) {

    private val bars = LevelBars()

    private val barPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = context.themeColor(androidx.appcompat.R.attr.colorPrimary)
    }
    private val clippedPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.dnt_warning)
    }

    /** The newest bar, for the record button's ring. See [LevelBars.newest]. */
    val newestLevel: Float get() = bars.newest

    fun appendLevels(incoming: List<AudioLevelMeter.Bar>) {
        if (bars.append(incoming)) invalidate()
    }

    fun clearLevels() {
        bars.clear()
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        bars.draw(canvas, width, height, barPaint, clippedPaint)
    }
}
