import Foundation

/// Packages raw Opus packets into an Ogg stream.
///
/// Needed because the two halves do not meet on their own. CoreAudio encodes Opus natively on
/// macOS and iOS, but will only wrap it in CAF; the API documents `audio/ogg`, and Opus-in-Ogg is
/// what it decodes. So the container has to be written here.
///
/// It is worth the ~200 lines. Measured against the same speech, a 30-second dictation is 960 kB
/// as 16 kHz PCM and 60 kB as Opus at 16 kbps — sixteen times less to upload — and end-to-end
/// latency fell from 11.4 s to 9.1 s at 30 s, and 6.9 s to 4.9 s at 10 s. The alternative was a
/// libopus dependency in four build systems.
///
/// Deliberately minimal: one logical stream, mono, the fixed 48 kHz Opus clock, and no seeking
/// support. A dictation is written once and uploaded once.
public struct OggOpusWriter {
    /// Opus always reports timestamps at 48 kHz regardless of the rate the audio was captured at.
    /// Granule positions in the wrong clock make the file play at the wrong speed, or be rejected.
    public static let opusClockRate = 48_000

    public var sampleRate: Int
    public var channels: Int
    /// Encoder delay to discard on playback, in 48 kHz samples. 312 is the CoreAudio default.
    public var preSkip: Int

    private var serial: UInt32
    private var sequence: UInt32 = 0
    private var granule: UInt64 = 0
    private var output = Data()

    /// Packets waiting to share a page, and the granule position the page will carry.
    ///
    /// One packet per page would be far simpler and was the first attempt. It also costs 28 bytes
    /// of page header for every 20 ms frame — 1.4 kB per second, which on a 16 kbps stream is very
    /// nearly as much again as the audio. It measured 27 kbps against `ffmpeg`'s 16 for identical
    /// input. Batching a second of audio per page reduces that overhead to noise.
    private var pending: [Data] = []
    private var pendingGranule: UInt64 = 0

    /// 50 × 20 ms. Larger pages save nothing measurable and delay nothing, since the whole file is
    /// written before any of it is sent.
    private static let packetsPerPage = 50

    /// - Parameter serialNumber: identifies the logical stream. Any value works for a single
    ///   stream; it is a parameter so tests can produce byte-identical output.
    public init(
        sampleRate: Int = 16_000, channels: Int = 1, preSkip: Int = 312,
        serialNumber: UInt32 = 0x646E_7401
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.preSkip = preSkip
        self.serial = serialNumber
    }

    /// Writes the two mandatory headers. Must be called before any audio.
    public mutating func begin() {
        output.append(page(payloads: [opusHead], headerType: 0x02, granule: 0))
        output.append(page(payloads: [opusTags], headerType: 0x00, granule: 0))
    }

    /// Appends one encoded Opus packet.
    ///
    /// - Parameter frameCount: decoded samples the packet represents, at the source sample rate.
    ///   Converted to the 48 kHz Opus clock internally, because that is what the granule position
    ///   must be expressed in.
    public mutating func append(packet: Data, frameCount: Int) {
        granule += UInt64(frameCount * Self.opusClockRate / max(sampleRate, 1))
        pending.append(packet)
        pendingGranule = granule

        if pending.count >= Self.packetsPerPage { flushPending(endOfStream: false) }
    }

    /// Finishes the stream and returns the complete file.
    ///
    /// The final page must carry the end-of-stream flag; without it, strict decoders treat the
    /// file as truncated and some reject it outright.
    public mutating func finish() -> Data {
        // The end-of-stream flag goes on the last page of real audio. The first attempt appended an
        // empty page to carry it, which is a zero-length packet — ffmpeg reads the duration
        // correctly and then fails with "Packet processing failed" at the end, because Opus has no
        // such thing as an empty packet.
        flushPending(endOfStream: true)
        return output
    }

    private mutating func flushPending(endOfStream: Bool) {
        guard !pending.isEmpty else { return }
        output.append(
            page(payloads: pending, headerType: endOfStream ? 0x04 : 0x00, granule: pendingGranule))
        pending.removeAll(keepingCapacity: true)
    }

    // MARK: - Headers

    private var opusHead: Data {
        var header = Data("OpusHead".utf8)
        header.append(1)  // version
        header.append(UInt8(channels))
        header.append(littleEndian: UInt16(preSkip))
        header.append(littleEndian: UInt32(sampleRate))  // informational only
        header.append(littleEndian: UInt16(0))  // output gain
        header.append(0)  // channel mapping family: mono/stereo
        return header
    }

    private var opusTags: Data {
        let vendor = Data("DoNotType".utf8)
        var tags = Data("OpusTags".utf8)
        tags.append(littleEndian: UInt32(vendor.count))
        tags.append(vendor)
        tags.append(littleEndian: UInt32(0))  // no user comments
        return tags
    }

    // MARK: - Page framing

    /// Builds one Ogg page.
    ///
    /// Packets larger than 255×255 bytes would need to span pages. A 20 ms Opus frame at any
    /// sane bitrate is a few hundred bytes, so the case cannot arise here and is not handled —
    /// silently truncating would be worse than not supporting it.
    private mutating func page(payloads: [Data], headerType: UInt8, granule: UInt64) -> Data {
        var segments = Data()
        var body = Data()

        for payload in payloads {
            var remaining = payload.count
            while remaining >= 255 {
                segments.append(255)
                remaining -= 255
            }
            segments.append(UInt8(remaining))
            body.append(payload)
        }

        var header = Data("OggS".utf8)
        header.append(0)  // stream structure version
        header.append(headerType)
        header.append(littleEndian: granule)
        header.append(littleEndian: serial)
        header.append(littleEndian: sequence)
        header.append(littleEndian: UInt32(0))  // CRC placeholder
        header.append(UInt8(segments.count))
        header.append(segments)
        header.append(body)

        sequence += 1

        // The CRC is computed over the whole page with the checksum field zeroed, then written
        // back into it — which is why it cannot be filled in above.
        let checksum = Self.crc32(header)
        withUnsafeBytes(of: checksum.littleEndian) { bytes in
            for (offset, byte) in bytes.enumerated() { header[22 + offset] = byte }
        }
        return header
    }

    /// Ogg's CRC-32: polynomial 0x04C11DB7, no reflection, zero initial value — not the CRC-32
    /// used by zip, which produces a wrong-but-plausible checksum that decoders reject.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }
}

extension Data {
    fileprivate mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
