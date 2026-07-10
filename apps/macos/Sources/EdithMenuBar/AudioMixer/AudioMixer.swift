import AppKit
import CoreAudio

struct MixerApp: Identifiable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage?
    var volume: Float
    var id: pid_t { pid }
}

@available(macOS 14.4, *)
enum AudioProcessRegistry {
    static func audioProcesses() -> [(objectID: AudioObjectID, pid: pid_t, bundleID: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { object in
            let pid = intProperty(object, kAudioProcessPropertyPID)
            guard pid > 0, let bundleID = stringProperty(object, kAudioProcessPropertyBundleID),
                !bundleID.isEmpty
            else { return nil }
            return (object, pid_t(pid), bundleID)
        }
    }

    private static func intProperty(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    )
        -> Int32
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Int32 = -1
        var size = UInt32(MemoryLayout<Int32>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    private static func stringProperty(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
            let string = value?.takeRetainedValue()
        else { return nil }
        return string as String
    }

    static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
            let value = uid?.takeRetainedValue()
        else { return nil }
        return value as String
    }
}

@available(macOS 14.4, *)
final class AppVolumeTap {
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.pulkit.edith.audiomixer.tap")
    nonisolated(unsafe) private var gain: Float = 1.0

    func setGain(_ value: Float) { gain = max(0, min(4, value)) }

    init?(processObjectID: AudioObjectID) {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(0)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != 0 else {
            return nil
        }
        tapID = tap
        guard let tapUID = tapUID(tap), let outputUID = AudioProcessRegistry.defaultOutputUID()
        else {
            destroy()
            return nil
        }
        let aggregateUID = "com.pulkit.edith.tap.\(UUID().uuidString)"
        let dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Edith Mixer",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var aggregate = AudioDeviceID(0)
        guard AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregate) == noErr,
            aggregate != 0
        else {
            destroy()
            return nil
        }
        aggregateID = aggregate
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) {
            [weak self] _, input, _, output, _ in
            guard let self else { return }
            let level = self.gain
            let inBuffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: input))
            let outBuffers = UnsafeMutableAudioBufferListPointer(output)
            for index in 0..<min(inBuffers.count, outBuffers.count) {
                let source = inBuffers[index]
                let destination = outBuffers[index]
                guard let sourceData = source.mData, let destinationData = destination.mData
                else { continue }
                let byteCount = Int(min(source.mDataByteSize, destination.mDataByteSize))
                let sampleCount = byteCount / MemoryLayout<Float>.size
                let sourceSamples = sourceData.assumingMemoryBound(to: Float.self)
                let destinationSamples = destinationData.assumingMemoryBound(to: Float.self)
                for sample in 0..<sampleCount {
                    destinationSamples[sample] = sourceSamples[sample] * level
                }
            }
        }
        guard status == noErr, let proc else {
            destroy()
            return nil
        }
        procID = proc
        AudioDeviceStart(aggregate, proc)
    }

    private func tapUID(_ tap: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &value) == noErr,
            let string = value?.takeRetainedValue()
        else { return nil }
        return string as String
    }

    func destroy() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    deinit { destroy() }
}
