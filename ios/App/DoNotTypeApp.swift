import DoNotTypeCore
import SwiftUI

@main
struct DoNotTypeApp: App {
    @State private var model: DictationModel
    @State private var files: FileTranscriptionModel

    /// Both built here so the file screen's model outlives navigating away from it — a forty-minute
    /// transcription is not something to lose by tapping Back.
    init() {
        let dictation = DictationModel()
        _model = State(initialValue: dictation)
        _files = State(initialValue: FileTranscriptionModel(dictation: dictation))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, files: files)
        }
    }
}

struct ContentView: View {
    @Bindable var model: DictationModel
    @Bindable var files: FileTranscriptionModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingInitialSetup: Bool
    @State private var showingSettings = false

    private static let initialSetupKey = "didCompleteInitialSetupV1"

    init(model: DictationModel, files: FileTranscriptionModel) {
        self.model = model
        self.files = files
        let arguments = ProcessInfo.processInfo.arguments
        let forceSetup = arguments.contains("-ui-testing-onboarding")
        let shouldShow = forceSetup || (
            !arguments.contains("-ui-testing")
                && !UserDefaults.standard.bool(forKey: Self.initialSetupKey)
                && !model.hasAPIKey
        )
        _showingInitialSetup = State(initialValue: shouldShow)
    }

    var body: some View {
        Group {
            if showingInitialSetup {
                InitialSetupView(model: model) {
                    UserDefaults.standard.set(true, forKey: Self.initialSetupKey)
                    showingInitialSetup = false
                }
            } else {
                dictationScreen
            }
        }
        // Keep the handoff at the root: on a first install the keyboard can open this URL while
        // setup is still on screen, before `dictationScreen` exists in the view hierarchy.
        .onOpenURL { url in
            guard url.scheme == "donottype" else { return }
            switch url.host {
            case "dictate":
                model.handleKeyboardLaunch()
            case "settings":
                showingSettings = true
            default:
                break
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showingSettings = false }
                                .accessibilityIdentifier("close-keyboard-settings")
                        }
                    }
            }
        }
        .overlay {
            if model.isReturnToHostPresented {
                KeyboardReturnToHostView(state: model.state) {
                    model.dismissReturnToHost()
                } cancel: {
                    model.cancelCurrentOperation()
                }
                .transition(.opacity)
            }
        }
    }

    private var dictationScreen: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                dictationModeBadge
                recordButton
                // Reserved rather than inserted: a meter that appears on the first word would push
                // the button under the thumb that is holding it.
                LevelMeter(bars: model.levels)
                    .frame(width: LevelMeter.width, height: 36)
                    .opacity(model.state == .recording ? 1 : 0)
                    .accessibilityHidden(true)
                statusLine
                Spacer()
                if let latest = model.records.first(where: { $0.status == .completed }) {
                    latestTranscript(latest)
                }
                pendingBanner
            }
            .padding(24)
            .navigationTitle("DoNotType")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { HistoryView(model: model) } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("History")
                    .accessibilityIdentifier("open-history")
                }
                // The offline half: a recording that already exists — a voice memo, a call — goes
                // through the same pipeline as speech into the microphone.
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        FileTranscriptionView(model: files)
                    } label: {
                        Image(systemName: "waveform.badge.plus")
                    }
                    .accessibilityLabel("Transcribe a recording")
                    .accessibilityIdentifier("open-files")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView(model: model) } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("open-settings")
                }
            }
        }
        .task {
            model.handleKeyboardLaunch()
            model.refreshDictionary()
            await model.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Anything that failed while offline goes out as soon as the app is foregrounded.
                model.refreshKeyboardSetupStatus()
                Task {
                    model.refreshDictionary()
                    await model.refresh()
                    await model.retryPending()
                }
            case .inactive, .background:
                // An ordinary app recording still stops here. A keyboard-initiated one continues
                // because the keyboard remains its visible recording surface.
                model.stopRecordingForBackground()
            @unknown default:
                model.stopRecordingForBackground()
            }
        }
    }

    /// The phone equivalent of the desktop's two hotkeys, plus the third thing a second stage can
    /// be. This chooses the operation only; what Rewrite and Translate each produce is configured
    /// in Settings, which is also where a target language is typed — a mode control that also
    /// carried a language list would be answering two questions at once, and the keyboard's copy
    /// of this control cannot type into itself at all.
    private var dictationModeBadge: some View {
        HStack(spacing: 3) {
            ForEach(LiveMode.allCases, id: \.self) { mode in
                modeButton(mode)
            }
        }
        .padding(3)
        .background(.quaternary, in: Capsule())
    }

    private func modeButton(_ mode: LiveMode) -> some View {
        let selected = model.liveMode == mode
        let availability = model.availability(of: mode)
        // Refused rather than stored when it cannot run: the model says why, in the sentence the
        // other three clients use.
        return Button(mode.label) { model.setLiveMode(mode) }
        .font(.caption.weight(.semibold))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor : Color.clear, in: Capsule())
        .buttonStyle(.plain)
        .disabled(model.state == .transcribing)
        .opacity(availability.isAvailable ? 1 : 0.55)
        .accessibilityIdentifier("mode-\(mode.rawValue)")
        .accessibilityHint(availability.reason ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var recordButton: some View {
        Button(action: {}) {
            ZStack {
                // The ring pulses with the newest bar, so the microphone is visibly live from the
                // corner of the eye that is watching the button rather than the meter.
                let newest = model.levels.last?.level ?? 0
                Circle()
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 10)
                    .frame(width: 168, height: 168)
                    .scaleEffect(1 + newest * 0.22)
                    .animation(.easeOut(duration: 0.08), value: newest)

                Circle()
                    .fill(model.state == .recording ? Color.red : Color.accentColor)
                    .frame(width: 132, height: 132)

                if model.state == .transcribing {
                    ThinkingDots()
                } else {
                    Image(systemName: model.state == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        // Tap toggles; holding records only while held. Both, for the same reason the desktop
        // hotkey supports both: hold-only means keeping a finger down for the length of a
        // thought, and toggle-only means a mis-tap leaves the microphone open.
        //
        // Recording starts on touch-down either way -- waiting to find out which gesture it is
        // would clip the first word, the one people say fastest.
        .contentShape(Circle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { model.pressBegan(at: $0.time) }
                .onEnded { model.pressEnded(at: $0.time) }
        )
        .disabled(model.state == .transcribing || !model.hasAPIKey)
        // The real Button makes the disabled state visible to VoiceOver as well as blocking touch.
        // Its visual gesture still starts on touch-down; VoiceOver uses the explicit action below.
        .accessibilityIdentifier("record")
        .accessibilityLabel(model.state == .recording ? "Stop dictating" : "Dictate")
        .accessibilityHint(
            model.hasAPIKey
                ? "Double tap to start and stop. Touch and hold to record only while held."
                : "Add an API key in Settings before dictating."
        )
        .accessibilityAction {
            if model.state == .recording {
                model.pressEnded()
            } else {
                model.pressBegan()
                model.pressEnded()
            }
        }
    }

    private var statusLine: some View {
        Group {
            switch model.state {
            case .idle:
                if model.hasAPIKey {
                    Text("Tap to dictate, or hold to talk").foregroundStyle(.secondary)
                } else {
                    NavigationLink {
                        SettingsView(model: model)
                    } label: {
                        Label("Add an API key in Settings", systemImage: "key")
                    }
                    .accessibilityIdentifier("configure-api-key")
                }
            case .recording:
                // Discard is offered here for the same reason Cancel is offered below: stopping
                // pays for the words. Until now the only way out of a recording you did not mean
                // was to let it finish and delete what it produced.
                VStack(spacing: 10) {
                    Text("Listening… tap to stop").foregroundStyle(.secondary)
                    Button("Discard recording", role: .destructive) {
                        model.cancelCurrentOperation()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("discard-recording")
                }
            case .transcribing:
                // Named, not a bare spinner: after you stop talking the wait is dead time, and the
                // user needs to know what is consuming it and retain a way out if the provider
                // never answers.
                VStack(spacing: 10) {
                    Text("Transcribing…").foregroundStyle(.secondary)
                    Button("Cancel transcription", role: .cancel) {
                        model.cancelCurrentOperation()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cancel-transcription")
                }
            case .notice(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .font(.callout)
    }

    private func latestTranscript(_ record: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest").font(.caption).foregroundStyle(.secondary)
            Text(record.text).lineLimit(4)
            Text("Copied to the clipboard, and waiting in the keyboard.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var pendingBanner: some View {
        if model.retryableCount > 0 {
            Button {
                Task { await model.retryAll() }
            } label: {
                Label(
                    "\(model.retryableCount) waiting to send — retry",
                    systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(!model.hasAPIKey)
        }
    }
}

/// The cold-start half of iOS voice-keyboard dictation. The app opens the microphone, attempts a
/// targeted return when iOS provided a host identifier, and gives honest manual instructions when
/// current iOS versions withhold it.
private struct KeyboardReturnToHostView: View {
    let state: DictationModel.State
    let dismiss: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: state == .recording ? "mic.fill" : "mic")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(state == .recording ? .red : Color.accentColor)

                Text(state == .recording ? "DoNotType is listening" : "Starting dictation…")
                    .font(.title.bold())

                VStack(spacing: 10) {
                    Text("Return to the app where you were typing")
                        .font(.headline)

                    Text("Swipe across the bottom edge to the previous app, or open it manually. Keep speaking — dictation continues after you leave DoNotType.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 420)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("keyboard-return-instructions")

                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 38, weight: .medium))
                    // A permanently repeating symbol prevents UI automation from ever observing
                    // the app as idle, and it keeps consuming animation work while somebody is
                    // speaking. Three pulses draw attention without turning this screen into an
                    // indefinite animation.
                    .symbolEffect(.pulse, options: .repeat(3))
                    .accessibilityHidden(true)

                if state == .recording || state == .transcribing {
                    Button(
                        state == .transcribing ? "Cancel transcription" : "Discard recording",
                        role: .cancel,
                        action: cancel
                    )
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cancel-keyboard-dictation")
                }
            }
            .padding(32)

            VStack {
                HStack {
                    Spacer()
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Dismiss return instructions")
                }
                Spacer()
            }
            .padding()
        }
    }
}

/// The last second and a half of the microphone, walking leftwards.
///
/// The ring alone answered "is the microphone live". It could not answer "how loud am I", which is
/// the question somebody asks when the transcript comes back wrong and they are wondering whether
/// they were heard at all. Every bar here is 60 ms of audio that actually happened, on the same
/// decibel scale as the desktop and the keyboard — see `AudioLevelMeter` for where the span came
/// from — so silence is a flat row of dots that keeps scrolling, and a voice is a shape.
///
/// Hidden from VoiceOver: it says nothing that the button's own label and the status line do not,
/// and a row of twenty-four unlabelled shapes is noise to somebody who cannot see it.
struct LevelMeter: View {
    let bars: [AudioLevelMeter.Bar]

    private static let barWidth = 4.0
    private static let spacing = 3.0
    static var width: Double {
        Double(DictationModel.visibleBars) * barWidth
            + Double(DictationModel.visibleBars - 1) * spacing
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    Capsule()
                        // Amber is not decoration: the input is loud enough to be clamped on the
                        // way in, and a recording distorted before it is sent is worth one colour.
                        .fill(bar.isClipping ? Color.orange : Color.accentColor)
                        .frame(
                            width: Self.barWidth,
                            // Silence is a row of dots rather than nothing at all: a meter that
                            // disappears when the room is quiet cannot be told apart from one that
                            // has stopped.
                            height: max(Self.barWidth, geometry.size.height * bar.level))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // One bar's worth, so the uneven arrival of readings does not show up as a stutter.
            .animation(.linear(duration: 0.05), value: bars)
        }
    }
}

/// The "still working" animation, shown once speech has stopped.
///
/// Deliberately unlike the recording ring, which is driven by the microphone. After the user stops
/// talking there is no input left to reflect, so anything level-driven would be decoration
/// pretending to be a signal. What this has to convey is only "not hung" — the failure it prevents
/// is someone concluding nothing happened and pressing the button again mid-request.
struct ThinkingDots: View {
    @State private var phase = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    // Each dot lags the one before it, so the group reads as motion in one
                    // direction rather than three things blinking independently.
                    let local = abs(sin(time * 3 - Double(index) * 0.7))
                    Circle()
                        .fill(.white.opacity(0.55 + 0.45 * local))
                        .frame(width: 12 + 5 * local, height: 12 + 5 * local)
                }
            }
        }
        .frame(height: 24)
    }
}
