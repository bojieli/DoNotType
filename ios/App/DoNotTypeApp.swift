import DoNotTypeCore
import SwiftUI

@main
struct DoNotTypeApp: App {
    @State private var model = DictationModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}

struct ContentView: View {
    @Bindable var model: DictationModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
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
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView(model: model) } label: {
                        Image(systemName: "gearshape")
                    }
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
                .onChanged { _ in model.pressBegan() }
                .onEnded { _ in model.pressEnded() }
        )
        .disabled(model.state == .transcribing)
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
