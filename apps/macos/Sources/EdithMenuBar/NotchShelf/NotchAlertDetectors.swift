import CoreAudio
import Foundation
import IOKit.ps

@MainActor
final class NotchAlertDetectors {
    private let post: (NotchAlert) -> Void
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var powerSource: CFRunLoopSource?
    private var lastOutputDevice: AudioDeviceID = 0
    private var lastCharging: Bool?
    private var lastCapacity: Int?
    private var warmingUp = true

    init(post: @escaping (NotchAlert) -> Void) {
        self.post = post
    }

    func start() {
        lastOutputDevice = Self.defaultOutputDevice()
        let snapshot = Self.readPower()
        lastCharging = snapshot.charging
        lastCapacity = snapshot.capacity
        startAudio()
        startPower()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.warmingUp = false
        }
    }

    func stop() {
        if let audioListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, audioListener
            )
        }
        audioListener = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
        }
        powerSource = nil
    }

    private func startAudio() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.audioChanged() }
        }
        audioListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    private func audioChanged() {
        let device = Self.defaultOutputDevice()
        guard device != lastOutputDevice, device != 0 else { return }
        lastOutputDevice = device
        guard !warmingUp else { return }
        post(
            NotchAlert(
                id: "audio.output", icon: "hifispeaker.fill", tint: "#4db3e6",
                title: Self.deviceName(device), subtitle: "Audio output", priority: .low,
                autoHide: 2.5))
    }

    private func startPower() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            let source = IOPSNotificationCreateRunLoopSource(
                { context in
                    guard let context else { return }
                    let detectors = Unmanaged<NotchAlertDetectors>.fromOpaque(context)
                        .takeUnretainedValue()
                    Task { @MainActor in detectors.powerChanged() }
                }, context)?.takeRetainedValue()
        else { return }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func powerChanged() {
        let now = Self.readPower()
        defer {
            lastCharging = now.charging
            lastCapacity = now.capacity
        }
        guard !warmingUp else { return }
        if let charging = now.charging, charging != lastCharging {
            let subtitle = now.capacity.map { "\($0)%" }
            if charging {
                post(
                    NotchAlert(
                        id: "power.charging", icon: "bolt.fill", tint: "#4cc47e",
                        title: "Charging", subtitle: subtitle, priority: .low, autoHide: 2.5))
            } else {
                post(
                    NotchAlert(
                        id: "power.charging", icon: "bolt.slash.fill", tint: "#e0a83f",
                        title: "On battery", subtitle: subtitle, priority: .low, autoHide: 2.5))
            }
        }
        if let capacity = now.capacity, let last = lastCapacity, capacity <= 20, last > 20 {
            post(
                NotchAlert(
                    id: "battery.low", icon: "battery.25", tint: "#e0664f", title: "Battery low",
                    subtitle: "\(capacity)%", priority: .high, autoHide: 4))
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func deviceName(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        guard status == noErr, let value = name?.takeRetainedValue() else { return "Output device" }
        return value as String
    }

    private static func readPower() -> (charging: Bool?, capacity: Int?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, nil) }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any]
            else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool
            let capacity = description[kIOPSCurrentCapacityKey] as? Int
            return (charging, capacity)
        }
        return (nil, nil)
    }
}
