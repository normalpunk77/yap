import CoreAudio
import Foundation

/// A microphone the user can pick in Settings. `id` is the live Core Audio device
/// (it renumbers across reboots and re-plugs), while `uid` is the stable string we
/// persist so the choice survives those renumberings.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
}

/// Enumerates and resolves audio input devices via Core Audio. Single home for the
/// HAL plumbing so both the mic picker (Settings) and capture (`MicrophoneCapture`)
/// share one implementation.
enum AudioInputDevices {
    /// Every input-capable device currently present, in Core Audio's own order.
    static func all() -> [AudioInputDevice] {
        deviceIDs().compactMap { device in
            guard hasInputStreams(device),
                  let uid = stringProperty(device, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(device, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(
                id: device,
                uid: uid,
                name: name,
                isBuiltIn: transportType(device) == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    /// The built-in microphone, if this Mac has one.
    static func builtIn() -> AudioInputDevice? { all().first { $0.isBuiltIn } }

    /// True when the system's current default OUTPUT device is Bluetooth (e.g. AirPods).
    /// Opening a mic while the user is listening on AirPods knocks them out of music mode
    /// (A2DP) into call mode (HFP), interrupting their audio — so callers can skip an
    /// otherwise-optional capture in that case.
    static func defaultOutputIsBluetooth() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        // Match BOTH Bluetooth transports: modern AirPods (Pro/Max on recent macOS) report
        // BluetoothLE, not classic Bluetooth — checking only the latter left the most common
        // case (the very AirPods this guard exists to protect) unguarded.
        let transport = transportType(device)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Resolve a persisted UID to a live device ID, or nil if that device is gone.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        all().first { $0.uid == uid }?.id
    }

    // MARK: - Core Audio plumbing

    private static func deviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &devices) == noErr else { return [] }
        return devices
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport)
        return transport
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // The HAL returns a +1-retained CFString for these properties, so take ownership
        // (takeRetainedValue) to avoid a leak. Unmanaged is pointer-sized POD, which keeps
        // the call free of the "object reference via raw pointer" hazard.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        let string = cf as String
        return string.isEmpty ? nil : string
    }
}
