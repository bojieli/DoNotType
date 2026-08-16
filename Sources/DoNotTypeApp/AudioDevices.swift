import AVFoundation
import AppKit
import CoreAudio
import Foundation
import ServiceManagement

/// Input device enumeration and selection.
///
/// Always using the system default is wrong in the one situation that matters most: you put on a
/// headset mid-session, macOS switches the default, and your dictation is suddenly coming through
/// whichever microphone the OS preferred. Being able to pin a device — and to see which one is
/// actually in use — is the difference between "it stopped working" and a setting.
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let isDefault: Bool
    }

    /// Every device with at least one input channel.
    static func inputs() -> [Device] {
        let defaultID = defaultInputID()
        return allDeviceIDs()
            .filter(hasInputChannels)
            .compactMap { id in
                guard let name = name(of: id) else { return nil }
                return Device(id: id, name: name, isDefault: id == defaultID)
            }
    }

    static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (name as String) : nil
    }

    static func defaultInputID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    /// Resolves a saved selection, falling back to the system default when the device is gone.
    ///
    /// Unplugging a pinned microphone must not stop dictation working; it should quietly use
    /// whatever is there and say so in settings.
    static func resolve(preferredUID: String?) -> AudioDeviceID? {
        guard let preferredUID, !preferredUID.isEmpty else { return nil }
        return inputs().first { uid(of: $0.id) == preferredUID }?.id
    }

    static func uid(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (uid as String) : nil
    }

    // MARK: - Private

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size = UInt32(0)
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)

        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }
}

/// Optional start/stop tones.
///
/// On by default, so recording boundaries remain clear when the overlay is behind another window.
/// The setting is still exposed for people who prefer silent dictation.
///
/// Two notes rather than one, because a single sound only tells you that *something* happened —
/// you then have to remember which of the two it was. An interval has a direction, and the ear
/// reads direction before it identifies a timbre: rising to open, the same interval falling to
/// close. Tink and Pop, the system sounds this used to borrow, are both single events, and Pop's
/// 1.6 seconds outlast the gesture that caused them by a wide margin.
@MainActor
enum InteractionSounds {
    /// Both cues are anchored on G4 so they are heard as one pair; start resolves a fourth up to
    /// C5, stop the same fourth down to D4.
    private static var start: NSSound? = Tone.pair(anchor: 392.00, resolvingTo: 523.25)
    private static var stop: NSSound? = Tone.pair(anchor: 392.00, resolvingTo: 293.66)

    static func playStart() {
        guard Settings.shared.interactionSounds else { return }
        start?.stop()
        start?.play()
    }

    static func playStop() {
        guard Settings.shared.interactionSounds else { return }
        stop?.stop()
        stop?.play()
    }
}

/// Synthesises the two-note cues as 16-bit PCM in memory.
///
/// Generated rather than shipped as .wav files: the whole voice is an envelope and three partials,
/// which is a dozen lines of arithmetic against two binary blobs that no reviewer can diff, no
/// diff can explain, and every packaging step has to remember to copy.
private enum Tone {
    private static let sampleRate = 48_000.0
    /// The second note lands while the first is still ringing, so the pair reads as one gesture
    /// rather than two beeps; each note is given a third of a second to decay into silence.
    private static let entry = 0.14
    private static let noteLength = 0.30
    /// Deliberately quiet: this marks a boundary under a keystroke, it does not announce an error.
    /// Tink peaks at 0.365 by comparison. Raise it here if the cue is getting lost in a room.
    private static let peak = 0.12

    static func pair(anchor: Double, resolvingTo second: Double) -> NSSound? {
        var samples = [Double](repeating: 0, count: Int((entry + noteLength) * sampleRate))
        strike(&samples, frequency: anchor, at: 0)
        strike(&samples, frequency: second, at: entry)
        return NSSound(data: wav(samples))
    }

    /// A struck-bar voice — fundamental, a quiet octave, and a third partial for the edge that
    /// keeps it from sounding like a test tone — under a shared exponential decay. The four
    /// millisecond attack exists only to stop the onset clicking; a hard start on a sine wave is a
    /// step change in air pressure, and it is audible as one.
    private static func strike(_ samples: inout [Double], frequency: Double, at start: Double) {
        let partials: [(multiple: Double, gain: Double)] = [(1, 1.0), (2, 0.18), (3, 0.22)]
        let offset = Int(start * sampleRate)
        for index in 0..<Int(noteLength * sampleRate) where offset + index < samples.count {
            let time = Double(index) / sampleRate
            let envelope = min(1, time / 0.004) * exp(-time / 0.09)
            let value = partials.reduce(0.0) { sum, partial in
                sum + partial.gain * sin(2 * .pi * frequency * partial.multiple * time)
            }
            samples[offset + index] += value * envelope
        }
    }

    /// Mono 16-bit PCM. `NSSound` will not take raw samples, only a container it recognises, and a
    /// 44-byte WAV header is the cheapest one to write.
    private static func wav(_ samples: [Double]) -> Data {
        // Summing three partials and two overlapping notes overshoots 1.0, so scale by what was
        // actually produced rather than by what the arithmetic was expected to produce.
        let loudest = samples.map(abs).max() ?? 0
        let scale = loudest > 0 ? peak / loudest : 0

        var body = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample * scale))
            withUnsafeBytes(of: Int16(clamped * 32767).littleEndian) { body.append(contentsOf: $0) }
        }

        var file = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) }
        }
        file.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + body.count))
        file.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                      // fmt chunk length
        append(UInt16(1))                       // PCM, uncompressed
        append(UInt16(1))                       // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)          // bytes per second
        append(UInt16(2))                       // block align
        append(UInt16(16))                      // bits per sample
        file.append(contentsOf: Array("data".utf8))
        append(UInt32(body.count))
        file.append(body)
        return file
    }
}

/// Registers the app to start with the user's session.
///
/// `SMAppService` rather than a login-item plist: the modern API surfaces the toggle in System
/// Settings › General › Login Items, so a user who forgets they enabled it can find and remove it
/// where they would expect to.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppServiceShim.isEnabled
        }
        return false
    }

    static func set(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            SMAppServiceShim.set(enabled)
        }
    }
}

@available(macOS 13.0, *)
private enum SMAppServiceShim {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration fails for an unsigned or non-bundled build, which is normal during
            // development and not worth interrupting anyone over.
        }
    }
}
