namespace DoNotType.Core;

/// <summary>
/// The two cues that say a recording started and stopped, as 16-bit PCM in a WAV container.
/// </summary>
/// <remarks>
/// Two notes rather than one, because a single sound only reports that <em>something</em> happened
/// -- which of the two it was is then a question of memory. An interval has a direction, and the
/// ear reads direction before it identifies a timbre: rising to open, the same interval falling to
/// close.
///
/// A hand port of <c>Tone.swift</c>, and kept structurally identical to it so the two can be read
/// side by side. Drift here would be silent -- Windows would simply sound slightly different, and
/// nothing would fail -- so <c>ToneTests</c> measures the notes on both sides rather than trusting
/// that a port stayed in step.
/// </remarks>
public static class Tone
{
    /// <summary>
    /// Both cues are anchored on G4 so they are heard as a pair rather than as two noises. Starting
    /// resolves a fourth up to C5, stopping the same fourth down to D4.
    /// </summary>
    private const double Anchor = 392.00;
    private const double Opening = 523.25;
    private const double Closing = 293.66;

    private const double SampleRate = 48_000.0;

    /// <summary>
    /// The second note enters while the first is still ringing, so the pair reads as one gesture
    /// rather than two beeps; each note is then given a third of a second to decay into silence.
    /// </summary>
    private const double Entry = 0.14;
    private const double NoteLength = 0.30;

    /// <summary>
    /// Deliberately quiet: this marks a boundary underneath a keystroke, it does not announce an
    /// error. Windows's own Asterisk is far louder. Raise it if the cue gets lost in a room.
    /// </summary>
    private const double Peak = 0.12;

    public static byte[] Start() => Pair(Opening);

    public static byte[] Stop() => Pair(Closing);

    private static byte[] Pair(double second)
    {
        var samples = new double[(int)((Entry + NoteLength) * SampleRate)];
        Strike(samples, Anchor, 0);
        Strike(samples, second, Entry);
        return Wav(samples);
    }

    /// <summary>
    /// A struck-bar voice -- fundamental, a quiet octave, and a third partial for the edge that
    /// keeps it from sounding like a test tone -- under a shared exponential decay. The four
    /// millisecond attack exists only to stop the onset clicking: a hard start on a sine wave is a
    /// step change in air pressure, and it is audible as one.
    /// </summary>
    private static void Strike(double[] samples, double frequency, double start)
    {
        (double Multiple, double Gain)[] partials = [(1, 1.0), (2, 0.18), (3, 0.22)];
        var offset = (int)(start * SampleRate);
        for (var index = 0; index < (int)(NoteLength * SampleRate); index++)
        {
            if (offset + index >= samples.Length)
            {
                break;
            }

            var time = index / SampleRate;
            var envelope = Math.Min(1, time / 0.004) * Math.Exp(-time / 0.09);
            var value = 0.0;
            foreach (var partial in partials)
            {
                value += partial.Gain * Math.Sin(2 * Math.PI * frequency * partial.Multiple * time);
            }

            samples[offset + index] += value * envelope;
        }
    }

    /// <summary>Mono 16-bit PCM at 48 kHz.</summary>
    /// <remarks>
    /// A second header writer next to <see cref="AudioChunker.WrapInWavContainer"/> is deliberate:
    /// that one describes the 16 kHz mono recording every transcription backend is fed, and its
    /// rate is baked into callers all the way out to the decoder. A cue played through the speakers
    /// is a different consumer, and widening the recording path's header to carry it would put a
    /// sample rate into eight call sites to serve two.
    /// </remarks>
    private static byte[] Wav(double[] samples)
    {
        // Summing three partials and two overlapping notes overshoots 1.0, so scale by what was
        // actually produced rather than by what the arithmetic was expected to produce.
        var loudest = 0.0;
        foreach (var sample in samples)
        {
            loudest = Math.Max(loudest, Math.Abs(sample));
        }

        var scale = loudest > 0 ? Peak / loudest : 0;

        using var stream = new MemoryStream(44 + (samples.Length * 2));
        using var writer = new BinaryWriter(stream);

        writer.Write("RIFF"u8);
        writer.Write(36 + (samples.Length * 2));
        writer.Write("WAVE"u8);
        writer.Write("fmt "u8);
        writer.Write(16);               // fmt chunk length
        writer.Write((short)1);         // PCM, uncompressed
        writer.Write((short)1);         // mono
        writer.Write((int)SampleRate);
        writer.Write((int)SampleRate * 2); // bytes per second
        writer.Write((short)2);         // block align
        writer.Write((short)16);        // bits per sample
        writer.Write("data"u8);
        writer.Write(samples.Length * 2);

        foreach (var sample in samples)
        {
            var clamped = Math.Max(-1, Math.Min(1, sample * scale));
            writer.Write((short)(clamped * 32767));
        }

        writer.Flush();
        return stream.ToArray();
    }
}
