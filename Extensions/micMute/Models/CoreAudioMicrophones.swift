import CoreAudio
import Foundation

@MainActor
enum CoreAudioMicrophones {
    static var access: MicrophoneAccess {
        MicrophoneAccess(controls: controls, read: read, write: write)
    }

    private static func controls() -> [MicrophoneControl] {
        inputDevices().flatMap { device in
            let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]
            for element in elements {
                let control = MicrophoneControl(device: device, element: element, kind: .mute)
                if isWritable(control) { return [control] }
            }
            return elements.compactMap { element in
                let control = MicrophoneControl(device: device, element: element, kind: .volume)
                return isWritable(control) ? control : nil
            }
        }
    }

    private static func address(_ control: MicrophoneControl) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: control.kind == .mute
                ? kAudioDevicePropertyMute : kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput, mElement: control.element)
    }

    private static func isWritable(_ control: MicrophoneControl) -> Bool {
        var property = address(control)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(control.device, &property)
            && AudioObjectIsPropertySettable(control.device, &property, &settable) == noErr
            && settable.boolValue
    }

    private static func read(_ control: MicrophoneControl) -> Float? {
        var property = address(control)
        var size: UInt32 = 4
        if control.kind == .mute {
            var value: UInt32 = 0
            guard
                AudioObjectGetPropertyData(control.device, &property, 0, nil, &size, &value)
                    == noErr
            else { return nil }
            return Float(value)
        }
        var value: Float = 0
        guard AudioObjectGetPropertyData(control.device, &property, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private static func write(_ control: MicrophoneControl, _ value: Float) -> Bool {
        var property = address(control)
        if control.kind == .mute {
            var encoded: UInt32 = value == 0 ? 0 : 1
            return AudioObjectSetPropertyData(control.device, &property, 0, nil, 4, &encoded)
                == noErr
        }
        var encoded = value
        return AudioObjectSetPropertyData(control.device, &property, 0, nil, 4, &encoded) == noErr
    }

    private static func inputDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
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
        return ids.filter { hasInputStreams($0) }
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

}
