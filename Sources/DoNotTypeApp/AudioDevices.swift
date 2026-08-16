import AVFoundation
import AppKit
import CoreAudio
import DoNotTypeCore
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
/// The cue itself is `Tone`, in the core, because it is shared with Windows. All that belongs here
/// is handing its bytes to AppKit — `NSSound` will not take raw samples, only a container it
/// recognises, which is why the core hands over a WAV rather than an array of floats.
@MainActor
enum InteractionSounds {
    private static var start: NSSound? = NSSound(data: Tone.start())
    private static var stop: NSSound? = NSSound(data: Tone.stop())

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
