import Foundation

/// Splits a long recording on silence so it can be transcribed in parallel.
///
/// A nine-minute dictation is roughly 17,000 audio tokens and a single request for it runs well
/// past any reasonable latency budget — the user has stopped talking and is waiting. Splitting on
/// silence and transcribing the pieces concurrently turns that into roughly the cost of the
/// slowest chunk.
///
/// Two rules make the seams survivable. Cuts land in silence, never mid-word, so no chunk begins
/// or ends on half a syllable. And every chunk is sent with the *same* screen context, which is
/// what keeps a name spelled consistently across a boundary — the alternative is chunk three
/// spelling something differently from chunk two for no reason the user can see.
public enum AudioChunker {
    /// Below this, one request is faster than the coordination.
    public static let threshold: TimeInterval = 90

    /// Boundary policy shared by finished files and the live recorder.
    ///
    /// `horizon` is deliberately not a maximum. It is the end of the preferred search interval;
    /// when there is no VAD-qualified pause by then, the chunk grows until one appears. A latency
    /// optimisation is never allowed to manufacture a mid-word cut.
    public struct BoundaryPolicy: Sendable, Equatable {
        public var minimum: TimeInterval
        public var target: TimeInterval
        public var horizon: TimeInterval
        public var minimumPause: TimeInterval
        public var preferredPause: TimeInterval

        public init(
            minimum: TimeInterval = 45,
            target: TimeInterval = 60,
            horizon: TimeInterval = 75,
            minimumPause: TimeInterval = 0.32,
            preferredPause: TimeInterval = 0.5
        ) {
            self.minimum = minimum
            self.target = target
            self.horizon = horizon
            self.minimumPause = minimumPause
            self.preferredPause = preferredPause
        }
    }

    public static let defaultPolicy = BoundaryPolicy()

    public struct Chunk: Sendable, Equatable {
        public let index: Int
        public let data: Data
        public let startSeconds: Double
        public let durationSeconds: Double
    }

    public struct Format: Sendable {
        public var sampleRate: Int
        public var channels: Int
        public var bitsPerSample: Int

        public init(sampleRate: Int = 16_000, channels: Int = 1, bitsPerSample: Int = 16) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.bitsPerSample = bitsPerSample
        }

        var bytesPerSecond: Int { sampleRate * channels * bitsPerSample / 8 }
    }

    /// Splits 16-bit PCM WAV data, or returns a single chunk when it is short enough.
    ///
    /// A cut is made only in a VAD-qualified pause. If the recording contains no such pause it is
    /// returned whole, however long it is.
    public static func split(
        wav: Data,
        format: Format = Format(),
        policy: BoundaryPolicy = defaultPolicy
    ) -> [Chunk] {
        guard let body = pcmBody(of: wav) else {
            return [Chunk(index: 0, data: wav, startSeconds: 0, durationSeconds: 0)]
        }

        let duration = Double(body.count) / Double(format.bytesPerSecond)
        guard duration > threshold else {
            return [Chunk(index: 0, data: wav, startSeconds: 0, durationSeconds: duration)]
        }

        var chunks: [Chunk] = []
        var start = 0

        while start < body.count {
            let remaining = body.count - start

            // A final piece shorter than the minimum is folded into this one rather than
            // left as a two-second fragment that transcribes badly on its own.
            if remaining <= Int(policy.target * Double(format.bytesPerSecond)) {
                chunks.append(
                    makeChunk(
                        index: chunks.count, body: body, range: start..<body.count, format: format))
                break
            }

            let tail = body.subdata(in: start..<body.count)
            guard let relativeCut = bestBoundary(in: tail, format: format, policy: policy) else {
                // No VAD pause means no safe boundary. One large request is slower; a cut through
                // speech is incorrect.
                chunks.append(
                    makeChunk(
                        index: chunks.count, body: body, range: start..<body.count, format: format))
                break
            }
            let cut = start + relativeCut

            // Offline splitting knows where the recording ends, so it can avoid creating a final
            // stub. The live segmenter cannot know the future and handles its tail on release.
            let finalSeconds = Double(body.count - cut) / Double(format.bytesPerSecond)
            if finalSeconds < policy.minimum {
                chunks.append(
                    makeChunk(
                        index: chunks.count, body: body, range: start..<body.count, format: format))
                break
            }
            chunks.append(
                makeChunk(index: chunks.count, body: body, range: start..<cut, format: format))
            start = cut
        }
        return chunks
    }

    /// Incremental counterpart to `split`. The recorder feeds it the exact PCM written to its
    /// recovery WAV; complete chunks come back as soon as a safe boundary can be committed.
    public struct StreamingSegmenter: Sendable {
        private var pending = Data()
        private var totalBytes = 0
        private var nextIndex = 0
        private var startBytes = 0
        private var emittedFirst = false
        private var bytesAtLastAnalysis = 0

        public let format: Format
        public let policy: BoundaryPolicy

        public init(format: Format = Format(), policy: BoundaryPolicy = defaultPolicy) {
            self.format = format
            self.policy = policy
        }

        public mutating func append(pcm: Data) -> [Chunk] {
            guard !pcm.isEmpty else { return [] }
            pending.append(pcm)
            totalBytes += pcm.count

            var ready: [Chunk] = []
            while shouldAnalyse,
                let cut = AudioChunker.bestBoundary(
                    in: pending, format: format, policy: policy)
            {
                let samples = pending.subdata(in: 0..<cut)
                ready.append(makeStreamingChunk(samples))
                pending.removeSubrange(0..<cut)
                startBytes += cut
                emittedFirst = true
                bytesAtLastAnalysis = 0
            }
            if ready.isEmpty, canConsiderBoundary { bytesAtLastAnalysis = pending.count }
            return ready
        }

        /// Returns the unsent tail on release. Nil means every sample was already emitted.
        public mutating func finish() -> Chunk? {
            guard !pending.isEmpty else { return nil }
            let samples = pending
            pending.removeAll(keepingCapacity: false)
            let chunk = makeStreamingChunk(samples)
            startBytes += samples.count
            return chunk
        }

        public var pendingDurationSeconds: Double {
            Double(pending.count) / Double(format.bytesPerSecond)
        }

        private var canConsiderBoundary: Bool {
            if !emittedFirst {
                return Double(totalBytes) / Double(format.bytesPerSecond) > AudioChunker.threshold
            }
            return pendingDurationSeconds >= policy.target
        }

        /// Re-running VAD for every 85 ms microphone tap would repeatedly scan the same minute of
        /// samples. Two hundred milliseconds is still below the minimum pause and bounds the extra
        /// latency while keeping capture work negligible.
        private var shouldAnalyse: Bool {
            canConsiderBoundary
                && (bytesAtLastAnalysis == 0
                    || pending.count - bytesAtLastAnalysis >= format.bytesPerSecond / 5)
        }

        private mutating func makeStreamingChunk(_ samples: Data) -> Chunk {
            defer { nextIndex += 1 }
            return Chunk(
                index: nextIndex,
                data: AudioChunker.wrapInWavContainer(samples, format: format),
                startSeconds: Double(startBytes) / Double(format.bytesPerSecond),
                durationSeconds: Double(samples.count) / Double(format.bytesPerSecond))
        }
    }

    // MARK: - Private

    private static func makeChunk(
        index: Int, body: Data, range: Range<Int>, format: Format
    ) -> Chunk {
        let samples = body.subdata(in: range)
        return Chunk(
            index: index,
            data: wrapInWavContainer(samples, format: format),
            startSeconds: Double(range.lowerBound) / Double(format.bytesPerSecond),
            durationSeconds: Double(samples.count) / Double(format.bytesPerSecond))
    }

    private struct PauseCandidate {
        let cut: Int
        let seconds: Double
        let duration: Double
        let depth: Double
    }

    /// Returns the best safe boundary, or nil when the audio has no VAD-qualified pause.
    ///
    /// VAD uses the recording's own low-percentile floor, so a train and a quiet office are judged
    /// relative to themselves. The second percentile is intentional: ordinary speech can contain
    /// less than ten percent pause, while a boundary detector only needs one sustained quiet run.
    /// A run counts as a boundary only when
    /// it is surrounded by speech; uniform noise therefore cannot masquerade as one enormous
    /// pause. The middle leaves acoustic context on both sides without duplicating samples.
    static func bestBoundary(
        in body: Data, format: Format = Format(), policy: BoundaryPolicy = defaultPolicy
    ) -> Int? {
        let frameMilliseconds = 20
        let frameBytes = format.bytesPerSecond * frameMilliseconds / 1_000
        guard frameBytes > 0, body.count >= frameBytes * 3 else { return nil }

        var levels: [Double] = []
        levels.reserveCapacity(body.count / frameBytes)
        body.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + frameBytes <= bytes.count {
                var energy = 0.0
                var samples = 0
                var index = offset
                let end = offset + frameBytes
                while index + 1 < end {
                    let sample = Int16(
                        bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
                    let value = Double(sample)
                    energy += value * value
                    samples += 1
                    index += 2
                }
                levels.append(
                    10 * log10(energy / Double(samples) / (32_768 * 32_768) + 1e-12))
                offset += frameBytes
            }
        }
        guard !levels.isEmpty else { return nil }

        let sorted = levels.sorted()
        let floor = sorted[min(sorted.count - 1, sorted.count / 50)]
        let speechThreshold = max(-65.0, floor + 8.0)
        let speaking = levels.map { $0 > speechThreshold }
        let minimumFrames = max(1, Int(ceil(policy.minimumPause * 1_000 / 20)))
        let evidenceFrames = 5  // 100 ms of speech on each side defeats isolated transients.
        let evidenceWindow = 100  // two seconds

        var candidates: [PauseCandidate] = []
        var frame = 0
        while frame < speaking.count {
            guard !speaking[frame] else {
                frame += 1
                continue
            }
            let runStart = frame
            while frame < speaking.count, !speaking[frame] { frame += 1 }
            let runEnd = frame
            guard runEnd - runStart >= minimumFrames else { continue }

            let beforeStart = max(0, runStart - evidenceWindow)
            let afterEnd = min(speaking.count, runEnd + evidenceWindow)
            let before = speaking[beforeStart..<runStart].filter { $0 }.count
            let after = speaking[runEnd..<afterEnd].filter { $0 }.count
            guard before >= evidenceFrames, after >= evidenceFrames else { continue }

            let middleFrame = runStart + (runEnd - runStart) / 2
            let seconds = Double(middleFrame * frameBytes) / Double(format.bytesPerSecond)
            guard seconds >= policy.minimum else { continue }

            let gapLevel = levels[runStart..<runEnd].reduce(0, +) / Double(runEnd - runStart)
            candidates.append(
                PauseCandidate(
                    cut: middleFrame * frameBytes,
                    seconds: seconds,
                    duration: Double(runEnd - runStart) * 0.02,
                    depth: max(0, speechThreshold - gapLevel)))
        }

        let preferred = candidates.filter { $0.seconds <= policy.horizon }
        if !preferred.isEmpty {
            return preferred.max { boundaryScore($0, policy: policy) < boundaryScore($1, policy: policy) }?.cut
        }

        // Past the decision horizon, use the first real pause instead of waiting for a prettier
        // one. Still no pause, still no cut.
        return candidates.min { $0.seconds < $1.seconds }?.cut
    }

    private static func boundaryScore(_ candidate: PauseCandidate, policy: BoundaryPolicy) -> Double {
        let preferredBonus = candidate.duration >= policy.preferredPause ? 3.0 : 0
        let duration = min(2, candidate.duration) * 4
        let depth = min(20, candidate.depth) / 10
        return preferredBonus + duration + depth - abs(candidate.seconds - policy.target)
    }

    /// Locates the `data` chunk, so a WAV with extra metadata chunks is handled correctly.
    static func pcmBody(of wav: Data) -> Data? {
        guard wav.count > 44, wav.prefix(4) == Data("RIFF".utf8) else { return nil }

        var cursor = 12
        while cursor + 8 <= wav.count {
            let id = wav.subdata(in: cursor..<(cursor + 4))
            let size = Int(
                UInt32(wav[cursor + 4]) | (UInt32(wav[cursor + 5]) << 8)
                    | (UInt32(wav[cursor + 6]) << 16) | (UInt32(wav[cursor + 7]) << 24))

            if id == Data("data".utf8) {
                let start = cursor + 8
                let end = min(start + size, wav.count)
                return start < end ? wav.subdata(in: start..<end) : nil
            }
            cursor += 8 + size + (size % 2)  // chunks are word-aligned
        }
        return nil
    }

    /// Reads the `fmt ` chunk, for the same reason `pcmBody` walks to `data`: nothing guarantees
    /// either sits at a fixed offset.
    ///
    /// `AVAudioFile` writes a 28-byte `JUNK` alignment chunk ahead of `fmt `, which is legal and
    /// common — it lets the header be rewritten in place without moving the samples. Reading the
    /// fields from the canonical offsets landed inside that padding instead, and because the
    /// padding is zeroes it produced a zero rate rather than an obviously wrong one, so every
    /// dictation the app stored recorded a length of 0 seconds and nothing failed loudly enough
    /// to notice.
    static func format(of wav: Data) -> Format? {
        guard wav.count > 44, wav.prefix(4) == Data("RIFF".utf8) else { return nil }

        var cursor = 12
        while cursor + 8 <= wav.count {
            let id = wav.subdata(in: cursor..<(cursor + 4))
            let size = Int(
                UInt32(wav[cursor + 4]) | (UInt32(wav[cursor + 5]) << 8)
                    | (UInt32(wav[cursor + 6]) << 16) | (UInt32(wav[cursor + 7]) << 24))

            // 16 bytes is the smallest legal `fmt `; the extensible variants only add fields
            // after the ones read here.
            if id == Data("fmt ".utf8), cursor + 8 + 16 <= wav.count {
                let body = cursor + 8
                func u16(_ offset: Int) -> Int {
                    Int(UInt16(wav[body + offset]) | (UInt16(wav[body + offset + 1]) << 8))
                }
                func u32(_ offset: Int) -> Int {
                    Int(
                        UInt32(wav[body + offset]) | (UInt32(wav[body + offset + 1]) << 8)
                            | (UInt32(wav[body + offset + 2]) << 16)
                            | (UInt32(wav[body + offset + 3]) << 24))
                }
                return Format(sampleRate: u32(4), channels: u16(2), bitsPerSample: u16(14))
            }
            cursor += 8 + size + (size % 2)  // chunks are word-aligned
        }
        return nil
    }

    static func wrapInWavContainer(_ pcm: Data, format: Format) -> Data {
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }

        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(format.channels))
        append(UInt32(format.sampleRate))
        append(UInt32(format.bytesPerSecond))
        append(UInt16(format.channels * format.bitsPerSample / 8))
        append(UInt16(format.bitsPerSample))
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        return header + pcm
    }

    /// Joins transcribed chunks.
    ///
    /// Chunks are cut in silence, so a plain join with a space is right — inserting punctuation
    /// would be inventing content, and the fidelity rules forbid that as firmly at a seam as
    /// anywhere else.
    public static func stitch(_ pieces: [String]) -> String {
        pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
