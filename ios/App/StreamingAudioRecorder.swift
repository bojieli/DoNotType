import AVFoundation
import DoNotTypeCore
import Foundation

/// iOS microphone capture that exposes the exact PCM written to its recovery WAV.
final class StreamingAudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputURL: URL?
    private var startedAt: Date?
    private var meter = AudioLevelMeter(sampleRate: 16_000)
    private var pendingBars: [AudioLevelMeter.Bar] = []

    var onPCM: (@Sendable (Data) -> Void)?
    var isRecording: Bool { engine.isRunning }

    func start(url: URL) throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: inputFormat, to: target)
        else { throw RecorderError.conversionUnavailable }
        self.converter = converter
        outputURL = url
        file = try AVAudioFile(
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
        lock.withLock {
            meter = AudioLevelMeter(sampleRate: 16_000)
            pendingBars.removeAll(keepingCapacity: true)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, target: target)
        }
        engine.prepare()
        try engine.start()
        startedAt = Date()
    }

    func stop() -> URL? {
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        teardown()
        guard let url = outputURL, elapsed >= PressGesture.minimumRecordingSeconds else {
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            outputURL = nil
            return nil
        }
        return url
    }

    func cancel() {
        teardown()
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }

    func drainLevels() -> [AudioLevelMeter.Bar] {
        lock.withLock {
            defer { pendingBars.removeAll(keepingCapacity: true) }
            return pendingBars
        }
    }

    private func teardown() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { file = nil }
        converter = nil
        startedAt = nil
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
