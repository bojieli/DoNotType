package app.donottype.ime

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.View
import app.donottype.core.AudioLevelMeter
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sin

/**
 * The two things a voice keyboard has to say without words: *I can hear you*, and *I am working*.
 *
 * They are drawn differently on purpose. The recording bars are driven by the actual microphone
 * level, so a dead mic looks dead -- an animation that plays regardless would be a liveness
 * indicator that lies. The transcribing animation is a travelling pulse with no input at all,
 * because after the user stops talking there is nothing to reflect; the only honest message is
 * "still going", and the thing it has to prevent is the user concluding the app has hung and
 * pressing the button again.
 */
class DictationIndicatorView(context: Context) : View(context) {
    enum class Mode { IDLE, RECORDING, TRANSCRIBING }

    companion object {
        /**
         * How much of the recording the meter shows: 24 bars of 60 ms, so a second and a half.
         * Long enough that the sentence being spoken is on screen, short enough for the bars to
         * stay readable on a phone.
         */
        const val VISIBLE_BARS = 24
    }

    var mode: Mode = Mode.IDLE
        set(value) {
            if (field == value) return
            field = value
            phase = 0.0
            // Only the transcribing pulse is drawn from a clock. The meter redraws when audio
            // arrives, which is the only time it has anything new to say.
            if (value == Mode.TRANSCRIBING) post(tick) else removeCallbacks(tick)
            if (value == Mode.RECORDING) clearLevels()
            invalidate()
        }

    /**
     * The visible history, oldest first. Always full: the meter starts flat rather than growing in
     * from the left, because an empty meter and a silent one should not look different.
     */
    private val bars = MutableList(VISIBLE_BARS) { AudioLevelMeter.Bar.SILENT }

    /** Adds however many bars the microphone has produced since the last redraw. */
    fun appendLevels(incoming: List<AudioLevelMeter.Bar>) {
        if (incoming.isEmpty()) return
        val kept = incoming.takeLast(VISIBLE_BARS)
        repeat(kept.size) { bars.removeAt(0) }
        bars += kept
        invalidate()
    }

    fun clearLevels() {
        for (index in bars.indices) bars[index] = AudioLevelMeter.Bar.SILENT
        invalidate()
    }

    private val barPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#E8EDF2") }
    // Amber is not decoration: the input is loud enough to be clamped on the way in, and a
    // recording distorted before it is sent is worth one colour.
    private val clippedPaint =
        Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#F0A05A") }
    private val pulsePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#7FB2FF") }
    private val rect = RectF()

    private var phase = 0.0

    /** ~30 fps. Fast enough to read as motion, slow enough not to matter on battery. */
    private val tick = object : Runnable {
        override fun run() {
            phase += 0.10
            invalidate()
            if (mode != Mode.IDLE) postDelayed(this, 33)
        }
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(tick)
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        when (mode) {
            Mode.IDLE -> Unit
            Mode.RECORDING -> drawBars(canvas)
            Mode.TRANSCRIBING -> drawThinking(canvas)
        }
    }

    /**
     * The last second and a half of the microphone, walking leftwards.
     *
     * What it replaced is worth saying, because it looked like this. Five bars driven by a single
     * current level -- a raw peak over a divisor -- and swayed by a travelling sine, so the level
     * sat pinned at the top through most of a normally-recorded voice and the movement was the
     * same whether the microphone was hearing a sentence or nothing at all. Here every bar is 60 ms
     * of audio that actually happened, and the meter moves because the audio does. Silence is a
     * flat row of dots that keeps scrolling: the microphone is live and hearing nothing.
     */
    private fun drawBars(canvas: Canvas) {
        val gap = width / (VISIBLE_BARS * 2.6f)
        val barWidth = (width - gap * (VISIBLE_BARS - 1)) / VISIBLE_BARS
        var x = 0f

        for (bar in bars) {
            // Silence is a row of dots rather than nothing at all: a meter that disappears when the
            // room is quiet cannot be told apart from one that has stopped.
            val barHeight = max(barWidth, height * 0.8f * bar.level.toFloat())
            rect.set(x, (height - barHeight) / 2f, x + barWidth, (height + barHeight) / 2f)
            canvas.drawRoundRect(
                rect, barWidth / 2f, barWidth / 2f,
                if (bar.isClipping) clippedPaint else barPaint,
            )
            x += barWidth + gap
        }
    }

    /** A dot travelling along a track. Deliberately unlike the recording bars: the user must be
     *  able to tell at a glance whether it is still listening or has moved on to thinking, and two
     *  animations that merely differ in speed do not answer that. */
    private fun drawThinking(canvas: Canvas) {
        val dots = 3
        val radius = height * 0.09f
        val spacing = radius * 3.2f
        val centreX = width / 2f
        val centreY = height / 2f

        for (index in 0 until dots) {
            // Each dot lags the one before it, so the group reads as motion in one direction
            // rather than three things blinking.
            val local = sin(phase * 3 - index * 0.7)
            val scale = (0.55 + 0.45 * abs(local)).toFloat()
            val x = centreX + (index - (dots - 1) / 2f) * spacing
            pulsePaint.alpha = (140 + 115 * abs(local)).toInt().coerceIn(0, 255)
            canvas.drawCircle(x, centreY, radius * scale, pulsePaint)
        }
    }
}
