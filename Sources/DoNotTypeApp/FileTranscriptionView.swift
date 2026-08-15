import DoNotTypeCore
import SwiftUI
import UniformTypeIdentifiers

/// Transcribe a recording that already exists.
///
/// Four controls and a text pane, deliberately. Everything else — provider, model, fidelity, key —
/// is the same configuration the dictation path uses, and duplicating those pickers here would
/// create a second place for them to disagree.
struct FileTranscriptionView: View {
    @Bindable var model: FileTranscriptionModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            dropZone
            Divider()
            controls
            Divider()
            results
            if let status = model.statusLine {
                Divider()
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    // MARK: - Files

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: model.files.isEmpty ? "waveform.badge.plus" : "waveform")
                .font(.system(size: 26))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

            if model.files.isEmpty {
                Text("Drop a recording here")
                Text("\(AudioDecoder.supportedFormats) — anything this Mac can play")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if model.files.count == 1, let first = model.files.first {
                Text(first.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(first.deletingLastPathComponent().path)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("\(model.files.count) recordings")
                Text(model.files.map(\.lastPathComponent).joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Button(model.files.isEmpty ? "Choose…" : "Choose other files…") {
                model.chooseFiles()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            load(providers)
            return true
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.url(from: provider) { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            await MainActor.run { _ = model.accept(urls: urls) }
        }
    }

    /// One dropped file, as a `URL`.
    ///
    /// Through `loadObject(ofClass:)` rather than `loadItem(forTypeIdentifier:)`, which returns
    /// `any NSSecureCoding` — a non-Sendable existential that cannot cross an `await`. Swift 6.2
    /// lets that pass and 6.0 does not, so it compiled here and failed on the CI toolchain. This
    /// form is also simply better: the callback hands back a `URL`, so there is no `Data`-or-`URL`
    /// unwrapping dance and nothing non-Sendable exists to escape in the first place.
    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Produce", selection: $model.mode) {
                    ForEach(TranscriptMode.allChoices, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .frame(maxWidth: 380)
                .disabled(model.phase.isRunning)

                Spacer()

                if model.phase.isRunning {
                    ProgressView().controlSize(.small)
                    Text(progressLabel).font(.callout).foregroundStyle(.secondary)
                    Button("Stop") { model.cancel() }
                } else {
                    Button("Transcribe") { model.start() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canStart)
                }
            }

            // Stated before the button is pressed, not discovered as an error afterwards.
            if let warning = model.modeWarning {
                Label(warning, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "Uses the service, model and fidelity from Settings. The transcript is stored in "
                    + "History like a dictation; the recording stays where it is."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private var progressLabel: String {
        switch model.phase {
        case .decoding: "Reading the file…"
        case .transcribing(let done, let total):
            total > 1 ? "Transcribing part \(done) of \(total)…" : "Transcribing…"
        case .deriving(let label): label
        default: ""
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if case .failed(let message) = model.phase {
            ContentUnavailableView {
                Label("That did not work", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Copy the error") { Diagnostics.copyToPasteboard(message) }
            }
        } else if model.outcome == nil {
            ContentUnavailableView(
                "No transcript yet",
                systemImage: "text.alignleft",
                description: Text(
                    "Pick a recording and press Transcribe. Long ones are split on silence and "
                        + "sent in parallel."))
        } else {
            VStack(spacing: 0) {
                HStack {
                    // The verbatim transcript is always kept, so it is always one click away —
                    // including for a summary, where it is the only way to check what was dropped.
                    if model.derivedSomething {
                        Picker("", selection: $model.display) {
                            Text("Result").tag(FileTranscriptionModel.Display.result)
                            Text("What was said").tag(FileTranscriptionModel.Display.verbatim)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                    }

                    Spacer()

                    Button("Copy") { model.copyResult() }
                    Button("Save…") { model.save() }
                    Button("Insert at cursor") {
                        Task { await model.insertAtCursor() }
                    }
                    .help("Types it where your cursor is, exactly as a dictation would")
                }
                .padding(8)

                Divider()

                ScrollView {
                    Text(model.visibleText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
    }
}
