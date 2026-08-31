package app.donottype.core

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import app.donottype.Settings
import app.donottype.audio.WavRecorder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Press, speak, release, get words back.
 *
 * This is the state machine, extracted from the keyboard so the app's own dictation screen runs the
 * same one rather than a second copy of it. The two surfaces differ in exactly two places: where
 * the words go afterwards, and what the screen behind them was — and those are the two things this
 * class asks its host for. Everything between the press and the transcript is here: the microphone
 * permission and API key preflight, the connection warm-up, the live session, the tap-versus-hold
 * timing, the level poll, and the request.
 *
 * It deliberately holds no words of its own. Every sentence a user reads while dictating belongs to
 * the surface they are looking at — a keyboard has one line and points at the app to fix things,
 * while the app screen has room and can fix them in place — so refusals come back as a [Refusal]
 * the host phrases itself, and results come back as a [Result] the host delivers itself.
 */
class DictationController(
    private val context: Context,
    private val scope: CoroutineScope,
    private val service: DictationService,
) {

    enum class State { IDLE, RECORDING, TRANSCRIBING, NOTICE, ERROR }

    /** Why a press did not become a dictation. The host supplies the sentence for each. */
    enum class Refusal {
        /** Nothing can be sent, so nothing is recorded. */
        NO_API_KEY,

        /** RECORD_AUDIO is not granted. An IME cannot ask for it; an activity can. */
        NO_MICROPHONE,

        /** A tap too brief for [WavRecorder.MIN_DURATION_MS]. Not an error, but not silence either. */
        TOO_SHORT,

        /** The audio stack refused to open. The throwable carries what it said. */
        COULD_NOT_START,
    }

    private val log = Log("dictate")
    private val recorder = WavRecorder()
    private val handler = Handler(Looper.getMainLooper())

    private var liveSession: LiveTranscriptionSession? = null
    private var pendingContext: ScreenContext? = null
    private var levelRunnable: Runnable? = null
    private var holdRunnable: Runnable? = null
    private var noticeJob: Job? = null
    private var transcribeJob: Job? = null
    private var pressStartedAt = 0L

    /** True once the press has lasted long enough to count as a hold rather than a tap. */
    private var pressBecameHold = false

    var state: State = State.IDLE
        private set(value) {
            field = value
            // Polling belongs to the state, not to the caller: every path out of RECORDING --
            // finishing, discarding, failing, the keyboard closing -- must stop it, and one place
            // that cannot be forgotten is cheaper than four that can.
            if (value == State.RECORDING) startLevelUpdates() else stopLevelUpdates()
            onState(value)
        }

    // MARK: - What the host supplies

    /** Called on every state change, on the main thread. */
    var onState: (State) -> Unit = {}

    /** Microphone levels as they are measured, while recording. */
    var onLevels: (List<AudioLevelMeter.Bar>) -> Unit = {}

    /**
     * The transcript, or the failure. The host delivers it and then chooses the next state with
     * [idle], [failed] or [notice] — because whether a dictation succeeded is partly about where
     * the words ended up, which only the host knows.
     */
    var onResult: (Result<DictationRecord>) -> Unit = {}

    /** Why the press was refused. The state is set after this returns. */
    var onRefused: (Refusal, Throwable?) -> Unit = { _, _ -> }

    /** What was on screen when the user began speaking, captured before recording starts. */
    var screenContext: () -> ScreenContext? = { null }

    /** Extra fields for the "recording started" line: which app, which field. */
    var logContext: () -> Map<String, String> = { emptyMap() }

    // MARK: - Gestures

    /**
     * Touch-down. [eventTime] is the touch's own timestamp, not the moment this ran: [begin]
     * blocks the UI thread while the audio stack is built, and the release that arrives during that
     * work would otherwise measure as a hold and end a recording the user had only tapped to start.
     * Both ends of the measurement are on `MotionEvent.getEventTime`'s uptime clock, which is also
     * the one [handler] schedules on.
     */
    fun pressDown(eventTime: Long = android.os.SystemClock.uptimeMillis()) {
        if (state == State.TRANSCRIBING) return

        // A second tap while already recording ends it. This is the toggle half of the gesture.
        if (state == State.RECORDING && !pressBecameHold) {
            finish()
            return
        }

        pressBecameHold = false
        pressStartedAt = eventTime
        begin()
        holdRunnable = Runnable { pressBecameHold = true }.also {
            handler.postDelayed(it, HOLD_THRESHOLD_MS)
        }
    }

    fun pressUp(cancelled: Boolean = false, eventTime: Long = android.os.SystemClock.uptimeMillis()) {
        holdRunnable?.let { handler.removeCallbacks(it) }
        holdRunnable = null

        if (cancelled) {
            // A finger dragged off the button, or the system stealing the gesture. Discard rather
            // than transcribe: the user did not choose to end here.
            if (state == State.RECORDING) {
                discard()
                state = State.IDLE
            }
            pressBecameHold = false
            return
        }

        val heldFor = eventTime - pressStartedAt
        if (heldFor >= HOLD_THRESHOLD_MS) {
            // It was a hold: releasing ends it.
            pressBecameHold = false
            finish()
        } else {
            // It was a tap: recording stays on until the next tap.
            pressBecameHold = false
        }
    }

    /** Forgets an in-flight press without touching the recording, for a surface going away. */
    fun cancelPress() {
        holdRunnable?.let { handler.removeCallbacks(it) }
        holdRunnable = null
        pressBecameHold = false
    }

    // MARK: - Dictation

    fun begin() {
        if (state == State.RECORDING || state == State.TRANSCRIBING) return
        // ERROR and NOTICE both render a live button. They must also accept it: previously ERROR
        // looked retryable but begin silently rejected every tap until the surface reopened.
        noticeJob?.cancel()
        state = State.IDLE

        // Do not capture speech that cannot be sent. The missing key is fixed before recording,
        // rather than reported after the user has talked.
        if (Settings.apiKey.isNullOrBlank()) {
            refuse(Refusal.NO_API_KEY)
            return
        }

        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            log.warn(
                mapOf("permission" to "RECORD_AUDIO"),
            ) { "cannot record: the microphone permission is not granted" }
            refuse(Refusal.NO_MICROPHONE)
            return
        }

        log.info(
            mapOf(
                "provider" to Settings.provider.id,
                "model" to Settings.model,
                "fidelity" to Settings.fidelity.id,
                "grounding" to if (Settings.groundingEnabled) "on" else "off",
            ) + logContext(),
        ) { "recording started" }

        // Opening a connection costs about a second, and whether the pooled one is still alive
        // cannot be known without using it -- so both happen here, against speech the user was
        // going to produce anyway, rather than after they stop with somebody watching.
        warmUpConnection()

        // The screen as it was when they began speaking, not as it is when the words arrive.
        pendingContext = screenContext()

        liveSession = service.createLiveSession(pendingContext)
        recorder.onPcm = liveSession?.let { session -> { pcm -> session.append(pcm) } }

        runCatching { recorder.start() }
            .onSuccess { state = State.RECORDING }
            .onFailure {
                recorder.onPcm = null
                liveSession?.cancel()
                liveSession = null
                log.error(mapOf("error" to (it.message ?: ""))) { "could not start recording" }
                refuse(Refusal.COULD_NOT_START, it)
            }
    }

    fun finish() {
        if (state != State.RECORDING) return

        val wav = recorder.stop()
        recorder.onPcm = null
        val screen = pendingContext
        pendingContext = null

        if (wav == null) {
            liveSession?.cancel()
            liveSession = null
            refuse(Refusal.TOO_SHORT)
            return
        }

        if (Settings.apiKey.isNullOrBlank()) {
            liveSession?.cancel()
            liveSession = null
            refuse(Refusal.NO_API_KEY)
            return
        }

        // Read at the moment the recording ends: this accepts a mode correction made while the
        // user was speaking, while a tap during the request cannot change what it becomes.
        val style = if (Settings.liveMode == LiveMode.REWRITE) {
            Settings.preferredRewriteStyle
        } else {
            RewriteStyle.VERBATIM
        }
        val live = liveSession
        liveSession = null

        state = State.TRANSCRIBING
        transcribeJob = scope.launch {
            val outcome = withContext(Dispatchers.IO) {
                service.transcribe(wav, screen, screen?.appName, style, live)
            }
            transcribeJob = null
            onResult(outcome)
        }
    }

    /**
     * Abandons a request that is already in flight, and returns the surface to [State.IDLE].
     *
     * The wait after somebody stops talking is dead time they cannot shorten, so a surface that
     * shows it must also offer a way out of it -- otherwise a provider that never answers leaves
     * the only control on the screen disabled indefinitely. Cancelling drops the words: nothing is
     * written to history, because [DictationService.transcribe] records the dictation only once it
     * has an outcome, and a cancelled one has none. That is the honest reading of the button --
     * the user is saying they no longer want this dictation, not that they want it filed as failed.
     *
     * The host writes whatever it wants to say afterwards; this only stops the work.
     */
    /**
     * Abandons whatever is in flight, whichever half of a dictation that is.
     *
     * One entry point rather than two, because the two hosts — the keyboard and the app's own
     * screen — both offer a single control and the state can change under the finger: a request
     * starts the moment the recording ends, and a Discard that became inert at exactly that
     * boundary would be a button that works except when it is most wanted.
     *
     * @return whether there was anything to abandon.
     */
    fun cancelActive(): Boolean {
        when (state) {
            State.RECORDING -> {
                discard()
                log.info { "recording discarded" }
                state = State.IDLE
            }
            State.TRANSCRIBING -> cancelTranscription()
            else -> return false
        }
        return true
    }

    fun cancelTranscription() {
        if (state != State.TRANSCRIBING) return
        transcribeJob?.cancel()
        transcribeJob = null
        discard()
        log.info { "dictation cancelled" }
        state = State.IDLE
    }

    /** Discards capture and every in-flight piece derived from it, without changing the state. */
    fun discard() {
        recorder.cancel()
        recorder.onPcm = null
        liveSession?.cancel()
        liveSession = null
        pendingContext = null
        stopLevelUpdates()
    }

    /** Everything above, plus the timers, for a host being destroyed. */
    fun dispose() {
        noticeJob?.cancel()
        transcribeJob?.cancel()
        transcribeJob = null
        cancelPress()
        discard()
    }

    // MARK: - States the host chooses

    /** Done, or dealt with: the button is pressable and the surface says its ordinary line. */
    fun idle() {
        state = State.IDLE
    }

    /** Something the host had to report. The button stays live; the message stays put. */
    fun failed() {
        state = State.ERROR
    }

    /**
     * A harmless outcome worth showing for a moment. The host writes the message first; this keeps
     * the surface out of its idle line for [NOTICE_MS] so the message is actually read.
     */
    fun notice() {
        noticeJob?.cancel()
        state = State.NOTICE
        noticeJob = scope.launch {
            delay(NOTICE_MS)
            if (state == State.NOTICE) state = State.IDLE
        }
    }

    // MARK: - Internals

    private fun refuse(reason: Refusal, error: Throwable? = null) {
        // The host phrases it before the state moves, so a render triggered by the state change
        // sees the message that belongs to it rather than the one it replaced.
        onRefused(reason, error)
        if (reason == Refusal.TOO_SHORT) notice() else failed()
    }

    /**
     * Opens the connection the dictation about to be recorded will need.
     *
     * Silent on failure by design: nothing has been asked for yet, so there is nothing to report.
     * A dead connection found here is replaced and the user never learns it happened.
     */
    private fun warmUpConnection() {
        val key = Settings.apiKey
        if (key.isNullOrBlank()) return
        scope.launch(Dispatchers.IO) {
            runCatching {
                ProviderFactory.create(Settings.provider, key, Settings.model).endpointOrigin
            }.getOrNull()?.let { ProviderTransport.warmUp(it) }
        }
    }

    private fun startLevelUpdates() {
        stopLevelUpdates()
        levelRunnable = object : Runnable {
            override fun run() {
                // Collects whatever the capture thread has measured since the last pass. A bar is
                // 60 ms of audio, so this asks about twice as often as one can appear and never
                // has to interpolate.
                onLevels(recorder.drainLevels())
                handler.postDelayed(this, LEVEL_POLL_MS)
            }
        }.also { handler.post(it) }
    }

    private fun stopLevelUpdates() {
        levelRunnable?.let { handler.removeCallbacks(it) }
        levelRunnable = null
    }

    companion object {
        /**
         * How long a press has to last before releasing it ends the recording.
         *
         * It is [WavRecorder.MIN_DURATION_MS] exactly, and the two are the same number on purpose:
         * a release may only end a recording the recorder would accept. While this was the shorter
         * 350 ms it read as the more comfortable choice, but it opened a 150 ms window where a
         * press was long enough to be called a hold and too short to survive
         * [WavRecorder.MIN_DURATION_MS]. A press landing in it stopped the recording and then threw
         * it away, so the gesture that felt most like a tap was the one guaranteed to produce
         * nothing. Nobody says anything in under half a second, so every press that used to send
         * still sends; what changes is that a press between the two lengths now leaves the
         * recording running, with the button still showing it, instead of discarding it in silence.
         */
        const val HOLD_THRESHOLD_MS = WavRecorder.MIN_DURATION_MS

        /** How long a notice stays before the surface returns to its idle line. */
        const val NOTICE_MS = 3_000L

        /** ~30 Hz. Twice as often as a bar can appear, so the meter never interpolates. */
        private const val LEVEL_POLL_MS = 33L
    }
}
