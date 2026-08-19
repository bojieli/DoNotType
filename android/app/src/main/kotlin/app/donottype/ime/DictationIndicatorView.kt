package app.donottype.ime

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.View
import app.donottype.core.AudioLevelMeter
import app.donottype.ui.LevelBars
import app.donottype.ui.ThinkingDots

/**
 * The two things a voice keyboard has to say without words: *I can hear you*, and *I am working*.
 *
 * They are drawn differently on purpose. The recording bars are driven by the actual microphone
 * level, so a dead mic looks dead -- an animation that plays regardless would be a liveness
 * indicator that lies. The transcribing animation is a travelling pulse with no input at all,
 * because after the user stops talking there is nothing to reflect; the only honest message is
 * "still going", and the thing it has to prevent is the user concluding the app has hung and
 * pressing the button again.
 *
 * Both drawings are [LevelBars] and [ThinkingDots], shared with the app's dictation screen. What
 * stays here is the keyboard's own palette: it draws on its own dark bar rather than on a themed
 * app surface, so its colours are literals and do not follow the system's light setting.
 */
class DictationIndicatorView(context: Context) : View(context) {
    enum class Mode { IDLE, RECORDING, TRANSCRIBING }

    var mode: Mode = Mode.IDLE
        set(value) {
            if (field == value) return
            field = value
            dots.reset()
            // Only the transcribing pulse is drawn from a clock. The meter redraws when audio
            // arrives, which is the only time it has anything new to say.
            if (value == Mode.TRANSCRIBING) post(tick) else removeCallbacks(tick)
            if (value == Mode.RECORDING) clearLevels()
            invalidate()
        }

    private val bars = LevelBars()
    private val dots = ThinkingDots()

    /** Adds however many bars the microphone has produced since the last redraw. */
    fun appendLevels(incoming: List<AudioLevelMeter.Bar>) {
        if (bars.append(incoming)) invalidate()
    }

    fun clearLevels() {
        bars.clear()
        invalidate()
    }

    private val barPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#E8EDF2") }
    // Amber is not decoration: the input is loud enough to be clamped on the way in, and a
    // recording distorted before it is sent is worth one colour.
    private val clippedPaint =
        Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#F0A05A") }
    private val pulsePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#7FB2FF") }

    /** ~30 fps. Fast enough to read as motion, slow enough not to matter on battery. */
    private val tick = object : Runnable {
        override fun run() {
            dots.advance()
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
            Mode.RECORDING -> bars.draw(canvas, width, height, barPaint, clippedPaint)
            Mode.TRANSCRIBING ->
                dots.draw(canvas, width / 2f, height / 2f, height * 0.09f, pulsePaint)
        }
    }
}
