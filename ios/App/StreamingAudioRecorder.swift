import AVFoundation
import DoNotTypeCore
import Foundation

/// iOS microphone capture that exposes the exact PCM written to its recovery WAV.
final class StreamingAudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var outputURL: URL?
    private var startedAt: Date?
    /// `engine.start()` can fail after the tap is installed. Track the tap independently from the
    /// engine's running state so a retry never tries to install a second tap on the same bus.
    private var tapInstalled = false
    private var meter = AudioLevelMeter(sampleRate: 16_000)
    private var pendingBars: [AudioLevelMeter.Bar] = []

    var onPCM: (@Sendable (Data) -> Void)?
    /// Runs for each input buffer, including while the session is warm but not recording.
    /// The bridge throttles the actual shared-container write to once a second.
    var onHeartbeat: (@Sendable () -> Void)?
    var isRecording: Bool { lock.withLock { startedAt != nil } }
    var isMonitoring: Bool { engine.isRunning }

    func start(url: URL) throws {
        guard !isRecording else { return }
        try configureEngineIfNeeded()
        guard let target = targetFormat else { throw RecorderError.conversionUnavailable }

        let recordingFile = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: target.commonFormat,
            interleaved: target.isInterleaved)

        outputURL = url
        lock.withLock {
            file = recordingFile
            startedAt = Date()
            meter = AudioLevelMeter(sampleRate: 16_000)
            pendingBars.removeAll(keepingCapacity: true)
        }

        do {
            try startEngineIfNeeded()
        } catch {
            lock.withLock {
                file = nil
                startedAt = nil
            }
            outputURL = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Keeps the input engine alive after the file closes when a keyboard session is active.
    func stop(keepMonitoring: Bool = false) -> URL? {
        let elapsed = lock.withLock { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
        lock.withLock {
            file = nil
            startedAt = nil
        }
        if !keepMonitoring { stopMonitoring() }

        guard let url = outputURL, elapsed >= PressGesture.minimumRecordingSeconds else {
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            outputURL = nil
            return nil
        }
        return url
    }

    func cancel(keepMonitoring: Bool = false) {
        lock.withLock {
            file = nil
            startedAt = nil
        }
        if !keepMonitoring { stopMonitoring() }
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }

    /// Starts the containing app's short-lived background session without retaining microphone
    /// samples. Later keyboard presses can begin a file immediately through the command bridge.
    func enableMonitoring() throws {
        try configureEngineIfNeeded()
        try startEngineIfNeeded()
    }

    func stopMonitoring() {
        guard !isRecording else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        engine.reset()
        converter = nil
        targetFormat = nil
    }

    func drainLevels() -> [AudioLevelMeter.Bar] {
        lock.withLock {
            defer { pendingBars.removeAll(keepingCapacity: true) }
            return pendingBars
        }
    }

    private func configureEngineIfNeeded() throws {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
            let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                interleaved: true),
            let converter = AVAudioConverter(from: inputFormat, to: target)
        else { throw RecorderError.conversionUnavailable }

        self.converter = converter
        targetFormat = target
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, target: target)
        }
        tapInstalled = true
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    private func append(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        onHeartbeat?()
        lock.lock()
        defer { lock.unlock() }
        guard let file, let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return
        }
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
        guard conversionError == nil, converted.frameLength > 0,
            let channel = converted.int16ChannelData?[0]
        else { return }

        do { try file.write(from: converted) } catch { return }
        let samples = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
        pendingBars += meter.append(samples)
        if pendingBars.count > 120 { pendingBars.removeFirst(pendingBars.count - 120) }
        onPCM?(Data(bytes: channel, count: samples.count * MemoryLayout<Int16>.size))
    }

    enum RecorderError: LocalizedError {
        case conversionUnavailable
        var errorDescription: String? { "Could not convert microphone audio to 16 kHz mono." }
    }
}
