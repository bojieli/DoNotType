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

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                styleChips
                recordButton
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
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Anything that failed while offline goes out as soon as the app is foregrounded.
            Task {
                await model.refresh()
                await model.retryPending()
            }
        }
    }

    /// Verbatim, or one of the rewrites.
    ///
    /// The desktop makes this choice with a second hotkey — which key you hold decides, before you
    /// speak. A phone has no second key, so it is a picker above the button, and the rule the
    /// hotkey preserves is the one that matters: the choice is made *before* speaking. A menu
    /// between finishing a sentence and seeing it appear would defeat the point of dictating.
    ///
    /// Hidden when no configured backend can rewrite text at all — a recogniser has no text
    /// endpoint, so this is not a control that would work less well, it is one that cannot work.
    /// Shown even when a rewrite cannot run, greyed out with the reason underneath.
    ///
    /// It used to be hidden, on the reasoning that a control which cannot work is worse than one
    /// that is not there. It is not: a missing control cannot explain itself, and the feature ended
    /// up looking absent rather than unavailable — the question "where is the rewrite" has no
    /// answer on screen, while "why is this greyed out" does.
    @ViewBuilder private var styleChips: some View {
        let availability = model.rewriteAvailability

        Picker("Style", selection: $model.liveStyle) {
            ForEach(RewriteStyle.allCases, id: \.self) { style in
                Text(Self.chipLabel(style)).tag(style)
            }
        }
        .pickerStyle(.segmented)
        .disabled(
            !availability.isAvailable || model.state == .recording
                || model.state == .transcribing)
        .accessibilityIdentifier("style-picker")

        if let reason = availability.reason {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("style-unavailable")
        }
    }

    /// The style's own word rather than "rewrite", which is what somebody is waiting for.
    private static func chipLabel(_ style: RewriteStyle) -> String {
        switch style {
        case .verbatim: "Verbatim"
        case .formal: "Formal"
        case .concise: "Concise"
        case .bullets: "Bullets"
        }
    }

    private var recordButton: some View {
        ZStack {
            // The ring pulses with the microphone level, so it is obvious the mic is live.
            Circle()
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 10)
                .frame(width: 168, height: 168)
                .scaleEffect(1 + model.level * 0.22)
                .animation(.easeOut(duration: 0.08), value: model.level)

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
        // Tap toggles; holding records only while held. Both, for the same reason the desktop
        // hotkey supports both: hold-only means keeping a finger down for the length of a
        // thought, and toggle-only means a mis-tap leaves the microphone open.
        //
        // Recording starts on touch-down either way -- waiting to find out which gesture it is
        // would clip the first word, the one people say fastest.
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { model.pressBegan(at: $0.time) }
                .onEnded { model.pressEnded(at: $0.time) }
        )
        .disabled(model.state == .transcribing)
        // A raw gesture is invisible to VoiceOver, which had left the one control this app exists
        // for unusable by anyone driving it that way. Activating announces itself as a button and
        // toggles, since press-and-hold is not a gesture VoiceOver can forward.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("record")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(model.state == .recording ? "Stop dictating" : "Dictate")
        .accessibilityHint("Double tap to start and stop. Touch and hold to record only while held.")
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
            case .idle: Text("Tap to dictate, or hold to talk").foregroundStyle(.secondary)
            case .recording: Text("Listening… tap to stop").foregroundStyle(.secondary)
            case .transcribing:
                // Named, not a bare spinner: after you stop talking the wait is dead time, and the
                // user needs to know what is consuming it and that it will end.
                Text("Transcribing…").foregroundStyle(.secondary)
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
