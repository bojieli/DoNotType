import DoNotTypeCore
import SwiftUI
import UniformTypeIdentifiers

/// Transcribe a recording that already exists — a voice memo, a call recording, a file someone
/// sent you.
///
/// This is the one feature of the desktop app that iOS can have in full. The keyboard's limits are
/// about the microphone and the screen; a file in the Files app is neither, so `FileTranscriber`
/// from `DoNotTypeCore` runs here exactly as it does on macOS, with the same three modes.
///
/// The picker reaches iCloud Drive and every file provider, so "the recording is on my Mac" is
/// solved by the platform rather than by us.
@MainActor
@Observable
final class FileTranscriptionModel {
    enum Phase: Equatable {
        case idle
        case decoding
        case transcribing(done: Int, of: Int)
        case deriving(String)
        case finished
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .decoding, .transcribing, .deriving: true
            default: false
            }
        }
    }

    enum Display: String, CaseIterable { case result, verbatim }

    private(set) var phase: Phase = .idle
    private(set) var outcome: FileTranscriber.Outcome?
    private(set) var statusLine: String?
    var fileName: String?
    var display: Display = .result

    var mode: TranscriptMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "fileMode") }
    }

    private let dictation: DictationModel
    private let log = Log("filescreen")
    private var task: Task<Void, Never>?

    init(dictation: DictationModel) {
        self.dictation = dictation
        self.mode = TranscriptMode(rawValue: UserDefaults.standard.string(forKey: "fileMode") ?? "")
            ?? .verbatim
    }

    var hasAPIKey: Bool { dictation.hasAPIKey }
    var settingsModel: DictationModel { dictation }

    var visibleText: String {
        guard let outcome else { return "" }
        return display == .verbatim ? outcome.verbatim : outcome.delivered
    }

    var derivedSomething: Bool {
        guard let outcome else { return false }
        return outcome.mode != .verbatim && outcome.delivered != outcome.verbatim
    }

    /// Why the chosen mode cannot run, before the button is pressed rather than after the upload.
    var modeWarning: String? {
        guard mode.needsSecondPass, dictation.provider.isSpeechRecognition else { return nil }
        if let helper = modelBackend {
            return "\(dictation.provider.displayName) only transcribes, so "
                + "\(helper.displayName) will write the result in a second request."
        }
        return "\(dictation.provider.displayName) is a speech recognition service: it cannot "
            + "rewrite or summarise. Add a key for Google or OpenRouter in Settings, or choose "
            + "Verbatim."
    }

    /// The first configured model backend, for the second stage a recogniser cannot run.
    private var modelBackend: ProviderKind? {
        ProviderKind.allCases.first {
            !$0.isSpeechRecognition && !(KeychainStore.read(account: $0.rawValue) ?? "").isEmpty
        }
    }

    // MARK: - Running

    func start(url: URL) {
        task?.cancel()
        outcome = nil
        statusLine = nil
        fileName = url.lastPathComponent
        phase = .decoding
        task = Task { [weak self] in await self?.run(url: url) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        statusLine = "Cancelled."
    }

    private func run(url: URL) async {
        // A file picked out of iCloud Drive or another provider is security-scoped: reading it
        // without this returns "no such file", which is a confusing way to say "not yours yet".
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let transcriber = dictation.makeFileTranscriber(secondStage: modelBackend) else {
            phase = .failed("Add your API key in Settings.")
            return
        }
        guard transcriber.supports(mode) else {
            phase = .failed(
                "\(dictation.provider.displayName) only transcribes audio. Choose Verbatim, or "
                    + "add a key for a model backend in Settings.")
            return
        }

        do {
            let produced = try await transcriber.transcribe(
                fileAt: url, mode: mode,
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.apply(progress) }
                })
            guard !Task.isCancelled else { return }

            outcome = produced
            display = .result
            phase = .finished
            statusLine = summary(produced)
            await dictation.store(produced)
        } catch {
            log.error(
                "file transcription failed",
                ["file": url.lastPathComponent, "error": error.localizedDescription])
            phase = .failed(error.localizedDescription)
        }
    }

    private func apply(_ progress: FileTranscriber.Progress) {
        switch progress {
        case .decoding: phase = .decoding
        case .transcribing(let done, let total): phase = .transcribing(done: done, of: total)
        // The mode's own word — "Summarising…", "Loosening…".
        case .deriving(let mode): phase = .deriving(mode.progressLabel)
        }
    }

    private func summary(_ outcome: FileTranscriber.Outcome) -> String {
        var parts: [String] = []
        if let duration = outcome.durationSeconds, duration > 0 {
            parts.append(
                "\(PerformanceStats.formatDuration(duration)) of audio in "
                    + PerformanceStats.formatDuration(outcome.totalSeconds))
        }
        if outcome.chunkCount > 1 { parts.append("\(outcome.chunkCount) parts") }
        if let second = outcome.secondStageProvider { parts.append("\(second) wrote the result") }
        return parts.joined(separator: " · ")
    }

    func copyResult() {
        guard !visibleText.isEmpty else { return }
        UIPasteboard.general.string = visibleText
        statusLine = "Copied \(visibleText.count) characters."
    }

    /// Hands it to the keyboard the same way a dictation is handed over, so it can be typed into
    /// any app rather than only pasted.
    func sendToKeyboard() {
        guard !visibleText.isEmpty else { return }
        dictation.deliverToKeyboard(visibleText)
        statusLine = "Waiting in the keyboard."
    }
}

struct FileTranscriptionView: View {
    @Bindable var model: FileTranscriptionModel
    @State private var isPickingFile = false

    var body: some View {
        Form {
            if !model.hasAPIKey {
                Section {
                    NavigationLink {
                        SettingsView(model: model.settingsModel)
                    } label: {
                        Label("Add an API key in Settings", systemImage: "key")
                    }
                } footer: {
                    Text("Choose a recording after a transcription provider is configured.")
                }
            }

            Section {
                Button {
                    isPickingFile = true
                } label: {
                    Label(
                        model.fileName ?? "Choose a recording…",
                        systemImage: model.fileName == nil ? "waveform.badge.plus" : "waveform")
                }
                .disabled(!model.hasAPIKey || model.phase.isRunning)
                .accessibilityIdentifier("choose-recording")

                Picker("Produce", selection: $model.mode) {
                    ForEach(TranscriptMode.allChoices, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .disabled(model.phase.isRunning)
                .accessibilityIdentifier("file-mode")

                if let warning = model.modeWarning {
                    Text(warning).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Recording")
            } footer: {
                // One string rather than three joined, so a translator can reach it. See
                // docs/LOCALIZATION.md.
                Text(
                    """
                    \(AudioDecoder.supportedFormats), and anything else this phone can play. \
                    Recordings over 90 seconds are split on silence and sent in parallel. \
                    The transcript is stored in History like a dictation.
                    """)
            }

            if model.phase.isRunning {
                Section {
                    HStack {
                        ProgressView()
                        Text(progressLabel).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { model.cancel() }
                    }
                }
            }

            if case .failed(let message) = model.phase {
                Section {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            if model.outcome != nil {
                Section {
                    // The verbatim transcript is always kept, so it is always one tap away —
                    // including under a summary, where it is the only way to see what was dropped.
                    if model.derivedSomething {
                        Picker("", selection: $model.display) {
                            Text("Result").tag(FileTranscriptionModel.Display.result)
                            Text("What was said").tag(FileTranscriptionModel.Display.verbatim)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Text(model.visibleText)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("file-transcript")

                    Button("Copy") { model.copyResult() }
                    Button("Send to the keyboard") { model.sendToKeyboard() }
                } header: {
                    Text("Result")
                } footer: {
                    if let status = model.statusLine {
                        Text(status)
                    }
                }
            }
        }
        .navigationTitle("Transcribe a Recording")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            model.start(url: url)
        }
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
}
