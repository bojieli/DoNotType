import AVFoundation
import DoNotTypeCore
import Foundation
import SwiftUI
import UIKit

/// Records, transcribes, and hands the result to the keyboard through the App Group.
///
/// There is no screen grounding on iOS. Nothing in the sandbox lets one app read another app's
/// content, and unlike macOS accessibility or Android's AccessibilityService there is no
/// user-grantable escape hatch. The `ScreenContext` this sends carries only what the user typed
/// into this app, which is usually nothing — so iOS gets verbatim transcription without the
/// grounding half of the product.
@MainActor
@Observable
final class DictationModel {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var transcripts: [TranscriptStore.Entry] = []
    private(set) var level: Double = 0

    var apiKey: String {
        didSet { KeychainStore.write(apiKey, account: "gemini") }
    }
    var fidelity: Fidelity {
        didSet { UserDefaults.standard.set(fidelity.rawValue, forKey: "fidelity") }
    }

    private let store = TranscriptStore()
    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var recordingURL: URL?

    init() {
        apiKey = KeychainStore.read(account: "gemini") ?? ""
        fidelity = Fidelity(rawValue: UserDefaults.standard.string(forKey: "fidelity") ?? "")
            ?? .default
        transcripts = store.load()
    }

    var hasAppGroup: Bool { TranscriptStore.containerURL != nil }

    func refresh() { transcripts = store.load() }

    // MARK: - Recording

    func toggleRecording() {
        switch state {
        case .recording: finishRecording()
        case .idle, .failed: Task { await beginRecording() }
        case .transcribing: break
        }
    }

    private func beginRecording() async {
        guard await requestMicrophone() else {
            state = .failed("Microphone access is required. Enable it in Settings › DoNotType.")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dnt-\(UUID().uuidString).wav")
            recordingURL = url

            // 16 kHz mono: the model downsamples to it regardless, so anything richer is upload
            // paid for and discarded.
            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                ])
            recorder.isMeteringEnabled = true
            recorder.record()
            self.recorder = recorder
            state = .recording
            startMetering()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func finishRecording() {
        levelTimer?.invalidate()
        levelTimer = nil
        recorder?.stop()
        recorder = nil
        level = 0

        guard let url = recordingURL else {
            state = .idle
            return
        }
        recordingURL = nil
        state = .transcribing
        Task { await transcribe(url: url) }
    }

    private func startMetering() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                // -50 dB is about the noise floor of a phone mic in a quiet room.
                let power = Double(recorder.averagePower(forChannel: 0))
                self.level = max(0, min(1, (power + 50) / 50))
            }
        }
    }

    private func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Transcription

    private func transcribe(url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }

        guard !apiKey.isEmpty else {
            state = .failed("Add your Gemini API key first.")
            return
        }

        do {
            let audio = try AudioFile(contentsOf: url)
            guard let promptURL = Bundle.main.url(forResource: "PROMPT", withExtension: "md") else {
                state = .failed("PROMPT.md is missing from the app bundle.")
                return
            }

            let result = try await GeminiProvider(apiKey: apiKey).transcribe(
                TranscriptionRequest(
                    model: ProviderKind.gemini.defaultModel,
                    systemInstruction: try PromptBuilder(contentsOf: promptURL)
                        .systemInstruction(fidelity: fidelity),
                    parts: [audio.part]))

            let text = result.transcript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                state = .idle
                return
            }

            store.append(text)
            transcripts = store.load()
            // Also to the pasteboard, so the transcript is usable even in apps where the user has
            // not enabled the keyboard.
            UIPasteboard.general.string = text
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func clearHistory() {
        store.clear()
        transcripts = []
    }
}

/// Keychain wrapper. The key never goes in `UserDefaults` — this is a bring-your-own-key app, so
/// the key is the whole privacy story.
enum KeychainStore {
    private static let service = "ai.19pine.donottype"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        SecItemAdd(base.merging([kSecValueData as String: Data(value.utf8)]) { _, new in new }
            as CFDictionary, nil)
    }
}
