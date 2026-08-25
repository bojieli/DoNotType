package app.donottype.core

/**
 * Splits a long recording on silence so it can be transcribed in parallel.
 *
 * A port of `AudioChunker.swift`, kept close to it deliberately -- the same constants, the same
 * cut placement, the same refusal to cut mid-sample. Anything that behaves differently here would
 * mean an Android transcript is stitched differently from a macOS one for no reason a user could
 * see.
 *
 * Whether an Android dictation is ever long enough to need this is a fair question, and the
 * argument for skipping it -- nobody holds a keyboard mic button for two minutes -- was never
 * measured. Porting it costs an afternoon and removes the question; leaving it out means a long
 * dictation behaves worse here than everywhere else, silently.
 *
 * Two rules make the seams survivable. Cuts land in silence, never mid-word. And every chunk is
 * sent with the *same* screen context, which is what keeps a name spelled consistently across a
 * boundary -- each request is independent and has no idea what the others produced.
 */
object AudioChunker {
    /** Below this, one request is faster than the coordination. */
    const val THRESHOLD_SECONDS = 90.0

    private const val SAMPLE_RATE = 16_000
    private const val BYTES_PER_SAMPLE = 2
    private const val BYTES_PER_SECOND = SAMPLE_RATE * BYTES_PER_SAMPLE

    data class BoundaryPolicy(
        val minimumSeconds: Double = 45.0,
        val targetSeconds: Double = 60.0,
        val horizonSeconds: Double = 75.0,
        val minimumPauseSeconds: Double = 0.32,
        val preferredPauseSeconds: Double = 0.5,
    )

    val defaultPolicy = BoundaryPolicy()

    data class Chunk(
        val index: Int,
        val data: ByteArray,
        val startSeconds: Double,
        val durationSeconds: Double,
    ) {
        // ByteArray in a data class needs these, or equality compares references.
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Chunk) return false
            return index == other.index && data.contentEquals(other.data) &&
                startSeconds == other.startSeconds && durationSeconds == other.durationSeconds
        }

        override fun hashCode(): Int = 31 * index + data.contentHashCode()
    }

    /**
     * Splits 16-bit PCM WAV data, or returns a single chunk when it is short enough.
     *
     * A cut is made only in an energy-qualified pause. No pause means no split.
     */
    fun split(wav: ByteArray, policy: BoundaryPolicy = defaultPolicy): List<Chunk> {
        val body = pcmBody(wav) ?: return listOf(Chunk(0, wav, 0.0, 0.0))

        val duration = body.size.toDouble() / BYTES_PER_SECOND
        if (duration <= THRESHOLD_SECONDS) return listOf(Chunk(0, wav, 0.0, duration))

        val chunks = mutableListOf<Chunk>()
        var start = 0

        while (start < body.size) {
            if (body.size - start <= policy.targetSeconds * BYTES_PER_SECOND) {
                chunks += makeChunk(chunks.size, body, start, body.size)
                break
            }
            val relativeCut = bestBoundary(body.copyOfRange(start, body.size), policy)
            if (relativeCut == null) {
                chunks += makeChunk(chunks.size, body, start, body.size)
                break
            }
            val cut = start + relativeCut
            if ((body.size - cut).toDouble() / BYTES_PER_SECOND < policy.minimumSeconds) {
                chunks += makeChunk(chunks.size, body, start, body.size)
                break
            }
            chunks += makeChunk(chunks.size, body, start, cut)
            start = cut
        }
        return chunks
    }

    /** Incremental pause segmenter used by live microphone capture. */
    class StreamingSegmenter(private val policy: BoundaryPolicy = defaultPolicy) {
        private var pending = ByteArray(0)
        private var totalBytes = 0L
        private var startBytes = 0L
        private var nextIndex = 0
        private var emittedFirst = false
        private var bytesAtLastAnalysis = 0

        fun append(pcm: ByteArray): List<Chunk> {
            if (pcm.isEmpty()) return emptyList()
            pending += pcm
            totalBytes += pcm.size
            val ready = mutableListOf<Chunk>()
            while (shouldAnalyse()) {
                val cut = bestBoundary(pending, policy) ?: break
                val samples = pending.copyOfRange(0, cut)
                ready += make(samples)
                pending = pending.copyOfRange(cut, pending.size)
                startBytes += cut
                emittedFirst = true
                bytesAtLastAnalysis = 0
            }
            if (ready.isEmpty() && canConsider()) bytesAtLastAnalysis = pending.size
            return ready
        }

        fun finish(): Chunk? {
            if (pending.isEmpty()) return null
            val samples = pending
            pending = ByteArray(0)
            val chunk = make(samples)
            startBytes += samples.size
            return chunk
        }

        private fun canConsider(): Boolean = if (!emittedFirst) {
            totalBytes.toDouble() / BYTES_PER_SECOND > THRESHOLD_SECONDS
        } else {
            pending.size.toDouble() / BYTES_PER_SECOND >= policy.targetSeconds
        }

        private fun shouldAnalyse(): Boolean = canConsider() &&
            (bytesAtLastAnalysis == 0 || pending.size - bytesAtLastAnalysis >= BYTES_PER_SECOND / 5)

        private fun make(samples: ByteArray): Chunk = Chunk(
            index = nextIndex++,
            data = wrapInWavContainer(samples),
            startSeconds = startBytes.toDouble() / BYTES_PER_SECOND,
            durationSeconds = samples.size.toDouble() / BYTES_PER_SECOND,
        )
    }

    private fun makeChunk(index: Int, body: ByteArray, from: Int, to: Int): Chunk {
        val samples = body.copyOfRange(from, to)
        return Chunk(
            index = index,
            data = wrapInWavContainer(samples),
            startSeconds = from.toDouble() / BYTES_PER_SECOND,
            durationSeconds = samples.size.toDouble() / BYTES_PER_SECOND,
        )
    }

    private data class PauseCandidate(
        val cut: Int,
        val seconds: Double,
        val duration: Double,
        val depth: Double,
    )

    /**
     * Returns the best energy-qualified pause, or null rather than cutting speech. This only
     * chooses a split point; [SpeechActivity] uses Silero to decide whether to send it.
     */
    internal fun bestBoundary(body: ByteArray, policy: BoundaryPolicy = defaultPolicy): Int? {
        val frameMilliseconds = 20
        val frameBytes = BYTES_PER_SECOND * frameMilliseconds / 1_000
        val frameCount = body.size / frameBytes
        if (frameCount < 3) return null

        val levels = DoubleArray(frameCount)
        repeat(frameCount) { frame ->
            var energy = 0.0
            val from = frame * frameBytes
            var index = from
            while (index + 1 < from + frameBytes) {
                val sample = ((body[index].toInt() and 0xFF) or
                    (body[index + 1].toInt() shl 8)).toShort()
                energy += sample.toDouble() * sample.toDouble()
                index += 2
            }
            levels[frame] = 10 * kotlin.math.log10(
                energy / (frameBytes / 2) / (32_768.0 * 32_768.0) + 1e-12,
            )
        }

        val sorted = levels.sorted()
        val floor = sorted[minOf(sorted.lastIndex, sorted.size / 50)]
        val speechThreshold = maxOf(-65.0, floor + 8.0)
        val speaking = levels.map { it > speechThreshold }
        val minimumFrames = maxOf(
            1,
            kotlin.math.ceil(policy.minimumPauseSeconds * 1_000 / frameMilliseconds).toInt(),
        )
        val evidenceFrames = 5
        val evidenceWindow = 100
        val candidates = mutableListOf<PauseCandidate>()

        var frame = 0
        while (frame < speaking.size) {
            if (speaking[frame]) {
                frame++
                continue
            }
            val runStart = frame
            while (frame < speaking.size && !speaking[frame]) frame++
            val runEnd = frame
            if (runEnd - runStart < minimumFrames) continue

            val before = speaking.subList(maxOf(0, runStart - evidenceWindow), runStart).count { it }
            val after = speaking.subList(runEnd, minOf(speaking.size, runEnd + evidenceWindow)).count { it }
            if (before < evidenceFrames || after < evidenceFrames) continue

            val middle = runStart + (runEnd - runStart) / 2
            val seconds = middle.toDouble() * frameBytes / BYTES_PER_SECOND
            if (seconds < policy.minimumSeconds) continue
            val gap = levels.copyOfRange(runStart, runEnd).average()
            candidates += PauseCandidate(
                middle * frameBytes,
                seconds,
                (runEnd - runStart) * 0.02,
                maxOf(0.0, speechThreshold - gap),
            )
        }

        val preferred = candidates.filter { it.seconds <= policy.horizonSeconds }
        if (preferred.isNotEmpty()) return preferred.maxBy { boundaryScore(it, policy) }.cut
        return candidates.minByOrNull { it.seconds }?.cut
    }

    /**
     * How much a candidate's distance from the target may outweigh its quality.
     *
     * The penalty used to be the raw distance — linear, unbounded, and in the same units as
     * nothing else in the score — so it dominated: a clean 1.3 s sentence break ten seconds early
     * scored below a 0.4 s breath sitting on the target. Normalising by the width of the
     * acceptable window fixes the units. Measured over 60 real recordings: the median pause a cut
     * lands in goes from 0.76 s to 1.32 s and cuts landing in a pause of a second or more from
     * 40% to 60%, with the same number of chunks and a slightly shorter final chunk.
     */
    internal const val DISTANCE_WEIGHT = 6.0

    private fun boundaryScore(candidate: PauseCandidate, policy: BoundaryPolicy): Double =
        (if (candidate.duration >= policy.preferredPauseSeconds) 3.0 else 0.0) +
            minOf(2.0, candidate.duration) * 4 +
            minOf(20.0, candidate.depth) / 10 -
            DISTANCE_WEIGHT * kotlin.math.abs(candidate.seconds - policy.targetSeconds) /
            maxOf(1.0, policy.horizonSeconds - policy.minimumSeconds)

    /** Locates the `data` chunk, so a WAV carrying extra metadata still works. */
    internal fun pcmBody(wav: ByteArray): ByteArray? {
        if (wav.size <= 44) return null
        if (wav[0] != 'R'.code.toByte() || wav[1] != 'I'.code.toByte() ||
            wav[2] != 'F'.code.toByte() || wav[3] != 'F'.code.toByte()
        ) {
            return null
        }

        var cursor = 12
        while (cursor + 8 <= wav.size) {
            val size = (wav[cursor + 4].toInt() and 0xFF) or
                ((wav[cursor + 5].toInt() and 0xFF) shl 8) or
                ((wav[cursor + 6].toInt() and 0xFF) shl 16) or
                ((wav[cursor + 7].toInt() and 0xFF) shl 24)

            if (wav[cursor] == 'd'.code.toByte() && wav[cursor + 1] == 'a'.code.toByte() &&
                wav[cursor + 2] == 't'.code.toByte() && wav[cursor + 3] == 'a'.code.toByte()
            ) {
                val start = cursor + 8
                val end = minOf(start + size, wav.size)
                return if (start < end) wav.copyOfRange(start, end) else null
            }
            cursor += 8 + size + (size % 2) // chunks are word-aligned
        }
        return null
    }

    internal fun wrapInWavContainer(pcm: ByteArray): ByteArray {
        val header = ByteArray(44)
        var offset = 0

        fun ascii(text: String) {
            for (character in text) header[offset++] = character.code.toByte()
        }
        fun int32(value: Int) {
            header[offset++] = (value and 0xFF).toByte()
            header[offset++] = ((value shr 8) and 0xFF).toByte()
            header[offset++] = ((value shr 16) and 0xFF).toByte()
            header[offset++] = ((value shr 24) and 0xFF).toByte()
        }
        fun int16(value: Int) {
            header[offset++] = (value and 0xFF).toByte()
            header[offset++] = ((value shr 8) and 0xFF).toByte()
        }

        ascii("RIFF"); int32(36 + pcm.size); ascii("WAVE")
        ascii("fmt "); int32(16); int16(1); int16(1)
        int32(SAMPLE_RATE); int32(BYTES_PER_SECOND); int16(BYTES_PER_SAMPLE); int16(16)
        ascii("data"); int32(pcm.size)

        return header + pcm
    }

    /**
     * Joins transcribed chunks.
     *
     * Chunks are cut in silence, so a plain join with a space is right -- inserting punctuation
     * would be inventing content, and the fidelity rules forbid that as firmly at a seam as
     * anywhere else.
     */
    fun stitch(pieces: List<String>): String =
        pieces.map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" ")
}
