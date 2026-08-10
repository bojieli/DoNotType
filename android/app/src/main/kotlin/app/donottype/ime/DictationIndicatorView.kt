package app.donottype.ime

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.View
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
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

    var mode: Mode = Mode.IDLE
        set(value) {
            if (field == value) return
            field = value
            phase = 0.0
            if (value == Mode.IDLE) removeCallbacks(tick) else post(tick)
            invalidate()
        }

    /** Microphone level, 0–1. Only meaningful while recording. */
    var level: Float = 0f
        set(value) {
            field = value.coerceIn(0f, 1f)
        }

    private val barPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#E8EDF2") }
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

    /** Level-driven bars. Not a spectrum -- what a speaker needs is "it hears me", and amplitude
     *  answers that. A slow travelling wave keeps it alive during pauses without implying signal. */
    private fun drawBars(canvas: Canvas) {
        val bars = 5
        val weights = floatArrayOf(0.45f, 0.75f, 1f, 0.7f, 0.5f)
        val barWidth = width / (bars * 2.6f)
        val gap = barWidth * 1.6f
        val totalWidth = bars * barWidth + (bars - 1) * gap
        var x = (width - totalWidth) / 2f

        for (index in 0 until bars) {
            val travel = (sin(phase * 4 + index * 0.9) * 0.5 + 0.5).toFloat()
            val amplitude = max(0.12f, level) * weights[index]
            val barHeight = height * 0.18f + height * 0.62f * min(1f, amplitude * (0.65f + 0.35f * travel))
            rect.set(x, (height - barHeight) / 2f, x + barWidth, (height + barHeight) / 2f)
            canvas.drawRoundRect(rect, barWidth / 2f, barWidth / 2f, barPaint)
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
