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
        Button(action: model.toggleRecording) {
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

                Image(systemName: model.state == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.state == .transcribing)
    }

    private var statusLine: some View {
        Group {
            switch model.state {
            case .idle: Text("Tap to dictate").foregroundStyle(.secondary)
            case .recording: Text("Listening… tap to stop").foregroundStyle(.secondary)
            case .transcribing:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Transcribing…").foregroundStyle(.secondary)
                }
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
