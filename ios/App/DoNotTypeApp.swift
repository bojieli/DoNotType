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
            List {
                recordSection
                if !model.transcripts.isEmpty { transcriptSection }
                settingsSection
                explanationSection
            }
            .navigationTitle("DoNotType")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
    }

    private var recordSection: some View {
        Section {
            VStack(spacing: 16) {
                Button(action: model.toggleRecording) {
                    ZStack {
                        Circle()
                            .fill(model.state == .recording ? Color.red : Color.accentColor)
                            .frame(width: 116, height: 116)
                            .scaleEffect(1 + model.level * 0.18)
                            .animation(.easeOut(duration: 0.08), value: model.level)
                        Image(systemName: model.state == .recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.state == .transcribing)

                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private var transcriptSection: some View {
        Section("Recent") {
            ForEach(model.transcripts) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                    Text(entry.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Clear", role: .destructive) { model.clearHistory() }
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            SecureField("Gemini API key", text: $model.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Picker("Fidelity", selection: $model.fidelity) {
                Text("Raw — every um").tag(Fidelity.raw)
                Text("Light — your words").tag(Fidelity.light)
                Text("Tidy — plus punctuation").tag(Fidelity.tidy)
            }

            if !model.hasAppGroup {
                Label(
                    "App Group unavailable — the keyboard cannot read transcripts.",
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var explanationSection: some View {
        Section("Why the keyboard cannot record") {
            Text(
                """
                iOS does not let a keyboard extension open a microphone. "Allow Full Access" grants \
                network and a shared container — not the mic.

                So dictation happens here, and the DoNotType keyboard inserts what this app \
                produced. Transcripts also go to the clipboard, so they are usable anywhere.

                Screen grounding is macOS and Android only: nothing in the iOS sandbox lets one app \
                read another's content.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch model.state {
        case .idle: "Tap to dictate"
        case .recording: "Listening… tap to stop"
        case .transcribing: "Transcribing…"
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        if case .failed = model.state { return .red }
        return .secondary
    }
}
