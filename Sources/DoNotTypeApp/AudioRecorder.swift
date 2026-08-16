import AVFoundation
import DoNotTypeCore
import Foundation

/// Microphone capture, downsampled and written incrementally.
///
/// Two decisions worth stating. **16 kHz mono**: the model downsamples to 16 kHz and collapses to
/// one channel regardless, so anything richer is upload we pay for and throw away. **Encode on the
/// capture thread**: writing each converted buffer as it arrives means that when the user releases
/// the key the payload is already finished, rather than starting a conversion pass while they wait.
final class AudioRecorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case microphoneDenied
        /// Carries descriptions rather than the formats themselves: `AVAudioFormat` is a
        /// non-Sendable class, and an `Error` that holds one cannot cross an isolation boundary.
        /// Swift 6.2 lets it pass; 6.0 does not, and 6.0 is right — the error is only ever read.
        case converterUnavailable(from: String, to: String)
        case tooShort(seconds: Double)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Microphone access denied. Grant it in System Settings › Privacy & Security › Microphone."
            case .converterUnavailable(let from, let to):
                "Cannot convert \(from) to \(to)"
            case .tooShort(let seconds):
                "Recording too short (\(String(format: "%.2f", seconds))s)"
            }
        }
    }

    static let sampleRate = 16_000.0
    /// Below this, it was a stray key press rather than speech. Matches Typeless's own cutoff.
    static let minimumDuration = 0.5

    private let log = Log("audio")
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputURL: URL?
    private var startedAt: Date?
    /// Recent RMS, so the UI can show that the mic is live.
    private(set) var level: Float = 0

    var isRecording: Bool { engine.isRunning }

    /// Pays the audio stack's one-off setup cost at launch instead of inside the first key press.
    ///
    /// Reaching `inputNode` for the first time builds the input audio unit and opens the device.
    /// Measured cold on an M-series Mac it took 94–166 ms, and `start()` runs on the event-tap
    /// callback, so every millisecond of it is a millisecond the hotkey is not being read — see
    /// `HotkeyMonitor.seconds(from:to:)` for what that cost used to do to the first dictation.
    ///
    /// It opens the device without starting IO: `kAudioDevicePropertyDeviceIsRunningSomewhere`
    /// stays false afterwards, so no recording indicator appears and nothing is captured. Called
    /// off the main thread, because the point is to move the wait, not to move it to launch.
    func warmUp() {
        guard !engine.isRunning else { return }
        _ = engine.inputNode.outputFormat(forBus: 0)
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Pinned input device UID, or nil for the system default.
    ///
    /// Passed in rather than read from `Settings` because the recorder runs off the main actor.
    /// Unplugging a pinned microphone must not stop dictation working — `resolve` returns nil and
    /// capture falls back to whatever the system offers.
    var preferredDeviceUID: String?

    func start() throws {
        guard !engine.isRunning else { return }

        // Applied before the tap is installed; changing it afterwards has no effect on a stream
        // that is already running.
        if let deviceID = AudioDevices.resolve(preferredUID: preferredDeviceUID) {
            try? engine.inputNode.auAudioUnit.setDeviceID(deviceID)
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                channels: 1, interleaved: true)
        else {
            throw RecorderError.converterUnavailable(
                from: "\(inputFormat.sampleRate) Hz", to: "16 kHz mono")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.converterUnavailable(
                from: "\(inputFormat.sampleRate) Hz", to: "\(target.sampleRate) Hz")
        }
        self.converter = converter

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dnt-\(UUID().uuidString).wav")
        outputURL = url
        // `settings` fixes the format on disk; `commonFormat`/`interleaved` fix the format the file
        // accepts from `write(from:)`. Omitting the latter pair leaves it at the default Float32
        // deinterleaved, and handing that file the Int16 buffers the converter produces trips an
        // assertion inside CoreAudio — which aborts the process rather than throwing, so the write
        // in `append` cannot catch it. Both halves have to agree with `target`.
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: target.commonFormat,
            interleaved: target.isInterleaved)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, target: target)
        }

        engine.prepare()
        try engine.start()
        startedAt = Date()
    }

    /// Stops capture and returns the finished recording.
    func stop() throws -> AudioFile {
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        teardown()

        guard let url = outputURL else { throw RecorderError.tooShort(seconds: 0) }
        guard elapsed >= Self.minimumDuration else {
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.tooShort(seconds: elapsed)
        }
        return try AudioFile(contentsOf: url)
    }

    /// Aborts without producing a recording, and removes the partial file.
    func cancel() {
        teardown()
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }

    // MARK: - Private

    private func teardown() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { file = nil }  // closing the AVAudioFile finalises the WAV header
        converter = nil
        startedAt = nil
        level = 0
    }

    private func append(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, let converter else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return
        }

        // Clearing `pending` offers the tap buffer exactly once — `convert` keeps calling back
        // until it is told there is nothing more. The annotation is what lets a non-Sendable
        // `AVAudioPCMBuffer` be handed to a block the SDK types as `@Sendable`: in practice
        // `convert` runs that block synchronously, on this thread, before returning, so nothing
        // crosses a thread at all, and the lock above covers the only concurrency there is.
        nonisolated(unsafe) var pending: AVAudioPCMBuffer? = buffer
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            guard let next = pending else {
                status.pointee = .noDataNow
                return nil
            }
            pending = nil
            status.pointee = .haveData
            return next
        }

        if let conversionError {
            log.error("audio conversion failed: \(conversionError.localizedDescription)")
            return
        }
        guard converted.frameLength > 0 else { return }

        do {
            try file.write(from: converted)
            level = Self.rms(converted)
        } catch {
            log.error("audio write failed: \(error.localizedDescription)")
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum = 0.0
        for index in 0..<Int(buffer.frameLength) {
            let sample = Double(channel[index]) / 32768.0
            sum += sample * sample
        }
        return Float((sum / Double(buffer.frameLength)).squareRoot())
    }
}
