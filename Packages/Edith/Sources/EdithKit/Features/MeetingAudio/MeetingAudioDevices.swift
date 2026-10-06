import AudioToolbox
import CoreAudio
import Foundation

public struct MeetingAudioDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let virtual: Bool
    public let objectID: AudioDeviceID
}

public enum MeetingAudioDevices {
    public static func list() -> [MeetingAudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { objectID in
            guard let id = string(objectID, selector: kAudioDevicePropertyDeviceUID),
                let name = string(objectID, selector: kAudioObjectPropertyName)
            else { return nil }
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(
                objectID, &transportAddress, 0, nil, &transportSize, &transport)
            return MeetingAudioDevice(
                id: id, name: name,
                inputChannels: channels(objectID, scope: kAudioDevicePropertyScopeInput),
                outputChannels: channels(objectID, scope: kAudioDevicePropertyScopeOutput),
                virtual: transport == kAudioDeviceTransportTypeVirtual, objectID: objectID)
        }
    }

    public static func resolve(_ query: String, output: Bool) throws -> MeetingAudioDevice {
        let candidates = list().filter {
            output ? $0.outputChannels > 0 && $0.virtual : $0.inputChannels > 0
        }
        let matches = candidates.filter {
            $0.id == query || $0.name.caseInsensitiveCompare(query) == .orderedSame
        }
        guard matches.count == 1, let device = matches.first else {
            throw MeetingAudioLibrary.error(
                output
                    ? "Choose Edith Microphone from ed camera audio devices."
                    : "The microphone is unavailable. Choose one from ed camera audio devices.")
        }
        return device
    }

    public static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return nil }
        return id
    }

    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector)
        -> String?
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value as String?
    }

    private static func channels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(
            pointer.assumingMemoryBound(to: AudioBufferList.self)
        ).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
