import AVFoundation
import AudioToolbox
import Foundation
import os

/// Encodes captured PCM to Opus, wrapped in Ogg.
///
/// The reason is upload size. The same 30 seconds of speech is 960 kB as 16 kHz PCM and about
/// 60 kB as Opus at 16 kbps, and measured end-to-end latency fell from 11.4 s to 9.1 s at 30 s and
/// from 6.9 s to 4.9 s at 10 s. Nothing about the transcript changed — the same clip transcribed
/// identically as WAV, FLAC and Opus.
///
/// CoreAudio encodes Opus natively, so there is no third-party dependency; what it will not do is
/// produce an Ogg container, which is what the API decodes. `OggOpusWriter` covers that gap.
public final class OpusEncoder {
    public enum EncoderError: LocalizedError {
        case unsupported
        case converterFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported: "Opus encoding is not available on this system."
            case .converterFailed(let detail): "Opus encoding failed: \(detail)"
            }
        }
    }

    /// 16 kbps mono is what Typeless ships and is transparent for speech. Raising it buys nothing
    /// a transcription model can hear and costs the latency this exists to save.
    public static let bitRate = 16_000
    /// Opus encodes in fixed frames; 20 ms is the usual choice and what CoreAudio produces.
    public static let frameMilliseconds = 20

    private let log = Logger(subsystem: "app.donottype", category: "opus")

    /// Whether this system can encode Opus at all. Checked once, because the answer cannot change
    /// while the app is running and the caller needs it before recording starts.
    public static let isAvailable: Bool = {
        var size: UInt32 = 0
        var format = kAudioFormatOpus
        return AudioFormatGetPropertyInfo(
            kAudioFormatProperty_AvailableEncodeBitRates,
            UInt32(MemoryLayout<AudioFormatID>.size), &format, &size) == noErr && size > 0
    }()

    /// Converts a finished 16 kHz mono PCM WAV into Ogg Opus.
    ///
    /// Whole-file rather than streaming during capture, deliberately. Encoding as the buffers
    /// arrive would save perhaps a hundred milliseconds and puts a codec on the audio thread,
    /// where a stall is a dropped word rather than a slow request. The encode itself runs far
    /// faster than real time.
    public init() {}

    public func encode(wav: Data) throws -> Data {
        guard Self.isAvailable else { throw EncoderError.unsupported }
        guard let pcm = AudioChunker.pcmBody(of: wav) else { throw EncoderError.unsupported }

        let sampleRate = 16_000.0
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1,
                interleaved: true)
        else { throw EncoderError.unsupported }

        var outputDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(sampleRate) / 1000 * UInt32(Self.frameMilliseconds),
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0)

        guard let outputFormat = AVAudioFormat(streamDescription: &outputDescription),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw EncoderError.unsupported
        }
        converter.bitRate = Self.bitRate

        let framesPerPacket = Int(outputDescription.mFramesPerPacket)
        var writer = OggOpusWriter(sampleRate: Int(sampleRate), channels: 1)
        writer.begin()

        var offset = 0
        let bytesPerFrame = 2

        while offset < pcm.count {
            let framesRemaining = (pcm.count - offset) / bytesPerFrame
            guard framesRemaining > 0 else { break }
            let frames = min(framesPerPacket, framesRemaining)

            guard
                let input = AVAudioPCMBuffer(
                    pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(framesPerPacket))
            else { break }
            input.frameLength = AVAudioFrameCount(framesPerPacket)

            // The final partial packet is zero-padded rather than dropped. Opus only encodes whole
            // frames, and truncating here would clip the last syllable — which is exactly where
            // people put the word they care about.
            if let channel = input.int16ChannelData?[0] {
                memset(channel, 0, framesPerPacket * bytesPerFrame)
                pcm.withUnsafeBytes { raw in
                    let source = raw.baseAddress!.advanced(by: offset)
                    memcpy(channel, source, frames * bytesPerFrame)
                }
            }
            offset += frames * bytesPerFrame

            let output = AVAudioCompressedBuffer(
                format: outputFormat, packetCapacity: 1,
                maximumPacketSize: converter.maximumOutputPacketSize)

            var consumed = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return input
            }

            if let conversionError {
                throw EncoderError.converterFailed(conversionError.localizedDescription)
            }
            guard status != .error, output.packetCount > 0 else { continue }

            let length = Int(output.byteLength)
            let packet = Data(bytes: output.data, count: length)
            writer.append(packet: packet, frameCount: framesPerPacket)
        }

        let ogg = writer.finish()
        log.info("opus encode: \(wav.count) B wav -> \(ogg.count) B ogg")
        return ogg
    }
}
