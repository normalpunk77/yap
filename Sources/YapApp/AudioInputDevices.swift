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
    let isBluetooth: Bool
    let isVirtual: Bool

    init(id: AudioDeviceID, uid: String, name: String, isBuiltIn: Bool,
         isBluetooth: Bool = false, isVirtual: Bool = false) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isBluetooth = isBluetooth
        self.isVirtual = isVirtual
    }
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
            let transport = transportType(device)
            return AudioInputDevice(
                id: device,
                uid: uid,
                name: name,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE,
                isVirtual: transport == kAudioDeviceTransportTypeVirtual
                    || transport == kAudioDeviceTransportTypeAggregate)
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

    /// Choose the dictation input UID without touching Core Audio state.
    ///
    /// The ONE combination to avoid: capturing from a BLUETOOTH mic while the user
    /// listens on Bluetooth — that knocks the headset from music mode (A2DP) into call
    /// mode (HFP) and audibly degrades what they're hearing. A built-in/USB/wired mic
    /// can never do that, so an explicit non-Bluetooth selection is ALWAYS honored.
    /// (The old rule blindly forced the built-in mic whenever output was Bluetooth:
    /// on a Mac mini/Studio — no built-in mic — that returned nil and every dictation
    /// failed, and on laptops it silently overrode a perfectly safe USB selection.)
    static func preferredDictationInputUID(devices: [AudioInputDevice],
                                           preferredInputDeviceUID: String?,
                                           defaultOutputIsBluetooth: Bool) -> String? {
        let selected = preferredInputDeviceUID.flatMap { uid in devices.first { $0.uid == uid } }
        if let selected, !(defaultOutputIsBluetooth && selected.isBluetooth) {
            return selected.uid
        }
        // No usable selection: built-in mic → real wired input → any REAL input (a
        // Bluetooth mic beats failing on a Mac whose only input is the AirPods — HFP
        // is unavoidable there). Virtual/aggregate devices (BlackHole, Teams audio)
        // are dead last: "capturing" a loopback records silence, not the user.
        let builtIn = devices.first { $0.isBuiltIn }
        let realWired = devices.first { !$0.isBluetooth && !$0.isVirtual }
        let realAny = devices.first { !$0.isVirtual }
        return (builtIn ?? realWired ?? realAny ?? devices.first)?.uid
    }

    /// Production wrapper for the active dictation input policy.
    static func preferredDictationInputUID() -> String? {
        preferredDictationInputUID(
            devices: all(),
            preferredInputDeviceUID: AppConfig.preferredInputDeviceUID,
            defaultOutputIsBluetooth: defaultOutputIsBluetooth()
        )
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
