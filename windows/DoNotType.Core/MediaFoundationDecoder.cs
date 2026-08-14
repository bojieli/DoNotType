using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace DoNotType.Core;

/// <summary>
/// Decodes MP3, M4A/AAC, WMA and anything else Windows can play, through Media Foundation.
/// </summary>
/// <remarks>
/// <para>
/// This is the piece the other three platforms get for free — CoreAudio on Apple, MediaCodec on
/// Android — and .NET has no equivalent. The alternatives were a managed MP3/AAC decoder (thousands
/// of lines, and still no AAC) or a third-party package; Media Foundation is already on every
/// supported Windows, decodes everything the OS can play, and costs one file of interop.
/// </para>
/// <para>
/// The Source Reader is asked for PCM and nothing more. Asking it for 16 kHz mono as well is the
/// obvious thing and does not work: it will insert a <em>decoder</em> to turn MP3 into PCM, but not
/// a <em>resampler</em>, so the request is refused with an HRESULT that surfaces as "no decoder
/// installed" — which is not what happened. What comes back is the decoder's native format, and
/// <see cref="AudioDecoder.ToTargetPcm"/> finishes the job with the same code the WAV path uses.
/// </para>
/// <para>
/// <b>This runs only on Windows, and only CI runs it.</b> The vtable layouts are the risk and
/// cannot be checked by compiling, which is why every interface declares each preceding slot with
/// its index in a comment, and why the core tests also run on the windows-2022 runner. The first
/// version of this file passed review, compiled, and failed on the first real MP3 — at
/// <c>SetCurrentMediaType</c>, for the reason above.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public static class MediaFoundationDecoder
{
    private static readonly Log Log = new("audio");

    /// <summary>Whether this platform can run the Media Foundation path at all.</summary>
    public static bool IsAvailable => OperatingSystem.IsWindows();

    /// <summary>Decodes to 16 kHz mono WAV bytes.</summary>
    public static byte[] DecodeToWav(string path, string name)
    {
        if (!IsAvailable)
        {
            throw new AudioDecoder.DecodeException(
                $"{name} needs a system decoder, and this is not Windows.");
        }

        var started = DateTimeOffset.Now;
        Check(MFStartup(Version, 0), name, "MFStartup");
        try
        {
            Check(
                MFCreateSourceReaderFromURL(path, IntPtr.Zero, out var reader), name,
                "opening the file");
            try
            {
                var format = Configure(reader, name);
                var raw = ReadAll(reader, name);
                if (raw.Length == 0)
                {
                    throw new AudioDecoder.DecodeException($"{name} decoded to no audio at all.");
                }

                // Media Foundation hands back whatever the decoder natively produces — usually
                // 44.1 kHz stereo — and the managed path finishes the job.
                var pcm = AudioDecoder.ToTargetPcm(raw, format, name);

                Log.Info(() => "decoded recording", new Dictionary<string, string>
                {
                    ["file"] = name,
                    ["via"] = "media foundation",
                    ["from"] = $"{format.SampleRate} Hz, {format.Channels} ch, {format.BitsPerSample}-bit",
                    ["bytes"] = pcm.Length.ToString(),
                    ["ms"] = ((long)(DateTimeOffset.Now - started).TotalMilliseconds).ToString(),
                });
                return AudioChunker.WrapInWavContainer(pcm);
            }
            finally
            {
                Marshal.ReleaseComObject(reader);
            }
        }
        finally
        {
            MFShutdown();
        }
    }

    /// <summary>
    /// Selects the first audio stream, asks for uncompressed PCM, and reports what that turned out
    /// to be.
    /// </summary>
    /// <remarks>
    /// Only the major type and the subtype are set. Asking for 16 kHz mono as well seems obvious
    /// and fails: the Source Reader will insert a <em>decoder</em> to turn MP3 into PCM, but it
    /// will not insert a <em>resampler</em>, so a request the decoder cannot satisfy natively is
    /// refused outright with a "no decoder installed" HRESULT that means nothing of the kind. That
    /// is exactly how this first failed on CI. The rate and channel count come back from the reader
    /// and the managed path converts.
    /// </remarks>
    private static AudioDecoder.WavFormat Configure(IMFSourceReader reader, string name)
    {
        // Everything off, then audio on: a video file with a soundtrack must not decode its frames.
        reader.SetStreamSelection(MediaSourceAllStreams, false);
        reader.SetStreamSelection(FirstAudioStream, true);

        Check(MFCreateMediaType(out var type), name, "MFCreateMediaType");
        try
        {
            type.SetGUID(MajorType, AudioMajorType);
            type.SetGUID(SubType, PcmSubType);

            var status = reader.SetCurrentMediaType(FirstAudioStream, IntPtr.Zero, type);
            if (status < 0)
            {
                throw new AudioDecoder.DecodeException(
                    $"Windows has no decoder installed for {name}. Convert it to WAV first "
                    + "(ffmpeg -i in.m4a -ar 16000 -ac 1 out.wav).");
            }
        }
        finally
        {
            Marshal.ReleaseComObject(type);
        }

        // What the decoder actually produces, which is usually 44.1 kHz stereo.
        Check(
            reader.GetCurrentMediaType(FirstAudioStream, out var actual), name,
            "reading the decoded format");
        try
        {
            var rate = ReadUInt32(actual, SamplesPerSecond, fallback: 44_100);
            var channels = ReadUInt32(actual, NumChannels, fallback: 2);
            var bits = ReadUInt32(actual, BitsPerSample, fallback: 16);
            return new AudioDecoder.WavFormat(rate, channels, bits, IsFloat: false);
        }
        finally
        {
            Marshal.ReleaseComObject(actual);
        }
    }

    /// <summary>
    /// One attribute, or a sensible default.
    ///
    /// A media type is not obliged to carry every field, and a missing sample rate should mean
    /// "assume CD audio and let the resampler sort it out" rather than a failed transcription.
    /// </summary>
    private static int ReadUInt32(IMFMediaType type, Guid key, int fallback) =>
        type.GetUINT32(key, out var value) >= 0 && value > 0 ? value : fallback;

    private static byte[] ReadAll(IMFSourceReader reader, string name)
    {
        using var output = new MemoryStream();
        while (true)
        {
            Check(
                reader.ReadSample(
                    FirstAudioStream, 0, IntPtr.Zero, out var flags, out _, out var sample),
                name, "reading a sample");

            if ((flags & EndOfStream) != 0) break;
            if (sample == IntPtr.Zero) continue; // a gap or a format change; keep going

            var managed = (IMFSample)Marshal.GetObjectForIUnknown(sample);
            try
            {
                Check(managed.ConvertToContiguousBuffer(out var buffer), name, "flattening a sample");
                try
                {
                    Check(buffer.Lock(out var pointer, out _, out var length), name, "locking a buffer");
                    try
                    {
                        var bytes = new byte[length];
                        Marshal.Copy(pointer, bytes, 0, length);
                        output.Write(bytes, 0, length);
                    }
                    finally
                    {
                        buffer.Unlock();
                    }
                }
                finally
                {
                    Marshal.ReleaseComObject(buffer);
                }
            }
            finally
            {
                Marshal.Release(sample);
            }
        }
        return output.ToArray();
    }

    private static void Check(int result, string name, string what)
    {
        if (result >= 0) return;
        throw new AudioDecoder.DecodeException(
            $"Could not decode {name}: {what} failed (0x{result:X8}). If this is a format Windows "
            + "cannot play either, convert it to WAV first.");
    }

    // ---- Constants ------------------------------------------------------------------------------

    private const int Version = 0x00020070; // MF_VERSION for Windows 7 and later
    private const uint FirstAudioStream = 0xFFFFFFFC; // MF_SOURCE_READER_FIRST_AUDIO_STREAM
    private const uint MediaSourceAllStreams = 0xFFFFFFFE;
    private const int EndOfStream = 0x00000002; // MF_SOURCE_READERF_ENDOFSTREAM

    private static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid SubType = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    private static readonly Guid AudioMajorType = new("73647561-0000-0010-8000-00aa00389b71");
    private static readonly Guid PcmSubType = new("00000001-0000-0010-8000-00aa00389b71");
    private static readonly Guid NumChannels = new("37e48bf5-645e-4c5b-89de-ada9e29b696a");
    private static readonly Guid SamplesPerSecond = new("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    private static readonly Guid BitsPerSample = new("f2deb57f-40fa-4764-aa33-ed4f2d1ff669");

    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFStartup(int version, int flags);

    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFShutdown();

    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFCreateMediaType(out IMFMediaType type);

    [DllImport("mfreadwrite.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern int MFCreateSourceReaderFromURL(
        string url, IntPtr attributes, out IMFSourceReader reader);

    // ---- COM ------------------------------------------------------------------------------------
    //
    // Only the methods this file calls are given real signatures; every earlier slot is declared as
    // a placeholder so the vtable offsets line up. That is the part most likely to be wrong and
    // impossible to catch by compiling, which is why the slots are counted in comments.

    [ComImport, Guid("70ae66f2-c809-4e4f-8915-bdcb406b7993")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFSourceReader
    {
        void GetStreamSelection_();                                                    // 0
        // Explicitly a 4-byte Win32 BOOL. The default marshalling for `bool` on a COM interface is
        // the 2-byte VARIANT_BOOL, which would put the wrong width on the stack.
        [PreserveSig] int SetStreamSelection(
            uint index, [MarshalAs(UnmanagedType.Bool)] bool selected);                // 1
        void GetNativeMediaType_();                                                    // 2
        [PreserveSig] int GetCurrentMediaType(uint index, out IMFMediaType type);       // 3
        [PreserveSig] int SetCurrentMediaType(uint index, IntPtr reserved, IMFMediaType type); // 4
        void SetCurrentPosition_();                                                    // 5
        [PreserveSig] int ReadSample(                                                  // 6
            uint index, uint flags, IntPtr actualIndex, out int streamFlags,
            out long timestamp, out IntPtr sample);
        void Flush_();                                                                 // 7
        void GetServiceForStream_();                                                   // 8
        void GetPresentationAttribute_();                                              // 9
    }

    /// <summary>
    /// IMFMediaType derives from IMFAttributes, whose thirty methods come first. Only SetUINT32
    /// (slot 18) and SetGUID (slot 21) are used.
    /// </summary>
    [ComImport, Guid("44ae0fa8-ea31-4109-8d2e-4cae4997c555")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFMediaType
    {
        void GetItem_();            // 0
        void GetItemType_();        // 1
        void CompareItem_();        // 2
        void Compare_();            // 3
        [PreserveSig] int GetUINT32(                                                          // 4
            [MarshalAs(UnmanagedType.LPStruct)] Guid key, out int value);
        void GetUINT64_();          // 5
        void GetDouble_();          // 6
        void GetGUID_();            // 7
        void GetStringLength_();    // 8
        void GetString_();          // 9
        void GetAllocatedString_(); // 10
        void GetBlobSize_();        // 11
        void GetBlob_();            // 12
        void GetAllocatedBlob_();   // 13
        void GetUnknown_();         // 14
        void SetItem_();            // 15
        void DeleteItem_();         // 16
        void DeleteAllItems_();     // 17
        [PreserveSig] int SetUINT32([MarshalAs(UnmanagedType.LPStruct)] Guid key, int value); // 18
        void SetUINT64_();          // 19
        void SetDouble_();          // 20
        [PreserveSig] int SetGUID(                                                            // 21
            [MarshalAs(UnmanagedType.LPStruct)] Guid key,
            [MarshalAs(UnmanagedType.LPStruct)] Guid value);
    }

    /// <summary>
    /// IMFSample also derives from IMFAttributes: thirty slots, then six of its own before
    /// ConvertToContiguousBuffer at 38.
    /// </summary>
    [ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFSample
    {
        void Slot00_(); void Slot01_(); void Slot02_(); void Slot03_(); void Slot04_();
        void Slot05_(); void Slot06_(); void Slot07_(); void Slot08_(); void Slot09_();
        void Slot10_(); void Slot11_(); void Slot12_(); void Slot13_(); void Slot14_();
        void Slot15_(); void Slot16_(); void Slot17_(); void Slot18_(); void Slot19_();
        void Slot20_(); void Slot21_(); void Slot22_(); void Slot23_(); void Slot24_();
        void Slot25_(); void Slot26_(); void Slot27_(); void Slot28_(); void Slot29_();
        void GetSampleFlags_();     // 30
        void SetSampleFlags_();     // 31
        void GetSampleTime_();      // 32
        void SetSampleTime_();      // 33
        void GetSampleDuration_();  // 34
        void SetSampleDuration_();  // 35
        void GetBufferCount_();     // 36
        void GetBufferByIndex_();   // 37
        [PreserveSig] int ConvertToContiguousBuffer(out IMFMediaBuffer buffer); // 38
    }

    [ComImport, Guid("045fa593-8799-42b8-bc8d-8968c6453507")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFMediaBuffer
    {
        [PreserveSig] int Lock(out IntPtr buffer, out int maxLength, out int currentLength); // 0
        [PreserveSig] int Unlock();                                                          // 1
        [PreserveSig] int GetCurrentLength(out int length);                                  // 2
        [PreserveSig] int SetCurrentLength(int length);                                      // 3
        [PreserveSig] int GetMaxLength(out int length);                                      // 4
    }
}
