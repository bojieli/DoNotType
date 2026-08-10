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
     * @param targetSeconds preferred chunk length; cuts land at the quietest point near it.
     * @param windowSeconds how far either side of the target to search for silence.
     */
    fun split(wav: ByteArray, targetSeconds: Double = 60.0, windowSeconds: Double = 15.0): List<Chunk> {
        val body = pcmBody(wav) ?: return listOf(Chunk(0, wav, 0.0, 0.0))

        val duration = body.size.toDouble() / BYTES_PER_SECOND
        if (duration <= THRESHOLD_SECONDS) return listOf(Chunk(0, wav, 0.0, duration))

        val chunks = mutableListOf<Chunk>()
        val targetBytes = (targetSeconds * BYTES_PER_SECOND).toInt()
        val windowBytes = (windowSeconds * BYTES_PER_SECOND).toInt()
        var start = 0

        while (start < body.size) {
            // A final piece shorter than the search window is folded into this one rather than left
            // as a two-second fragment that transcribes badly on its own.
            if (body.size - start <= targetBytes + windowBytes) {
                chunks += makeChunk(chunks.size, body, start, body.size)
                break
            }
            val cut = quietestCut(body, start + targetBytes, windowBytes)
            chunks += makeChunk(chunks.size, body, start, cut)
            start = cut
        }
        return chunks
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

    /**
     * Finds the middle of the quietest 100 ms inside the search window.
     *
     * Quietest rather than "first below a threshold": an absolute threshold tuned for a quiet room
     * finds no silence at all on a bus, and would then cut mid-word. The *middle* rather than the
     * start, so both neighbours keep a little silence -- audio beginning on the first sample of a
     * word tends to lose that word's opening consonant.
     */
    internal fun quietestCut(body: ByteArray, centre: Int, window: Int): Int {
        val probe = maxOf(BYTES_PER_SAMPLE, BYTES_PER_SECOND / 10) // 100 ms
        val low = maxOf(0, centre - window)
        val high = minOf(body.size - probe, centre + window)
        if (low >= high) return minOf(centre, body.size)

        var quietest = centre
        var quietestEnergy = Double.MAX_VALUE
        // Coarse stride: energy every 20 ms. The cut only has to land somewhere quiet, not at the
        // single quietest byte.
        val stride = maxOf(BYTES_PER_SAMPLE, BYTES_PER_SECOND / 50)

        var position = low
        while (position < high) {
            val energy = meanEnergy(body, position, probe)
            if (energy < quietestEnergy) {
                quietestEnergy = energy
                quietest = position
            }
            position += stride
        }

        // Align to a sample boundary; a cut mid-sample produces a click.
        val middle = minOf(quietest + probe / 2, body.size)
        return middle - (middle % BYTES_PER_SAMPLE)
    }

    private fun meanEnergy(body: ByteArray, offset: Int, length: Int): Double {
        var total = 0.0
        var count = 0
        val end = minOf(offset + length, body.size - 1)

        var index = offset
        while (index < end) {
            val sample =
                ((body[index].toInt() and 0xFF) or (body[index + 1].toInt() shl 8)).toShort()
            total += sample.toDouble() * sample.toDouble()
            count++
            index += 2
        }
        return if (count == 0) Double.MAX_VALUE else total / count
    }

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
