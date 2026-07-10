import AppKit
import CoreAudio
import EdithKit

@MainActor
final class MicMuteEngine: NSObject, ObservableObject, FeatureModule {
    @Published private(set) var muted = false

    private var savedVolumes: [AudioDeviceID: [UInt32: Float]] = [:]
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var statusItem: NSStatusItem?

    override init() {
        super.init()
        muted = SharedDefaults.store.bool(forKey: "micMuted")
        if muted { apply(true) }
        observeDeviceList()
        updateStatusItemPresence()
    }

    func shutdown() {
        if muted { apply(false) }
        if let listener = deviceListListener {
            var address = Self.deviceListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
            deviceListListener = nil
        }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func toggle() { setMuted(!muted) }

    func setMuted(_ on: Bool) {
        guard on != muted else { return }
        muted = on
        SharedDefaults.store.set(on, forKey: "micMuted")
        apply(on)
        updateIcon()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    func updateStatusItemPresence() {
        let wanted = SharedDefaults.store.object(forKey: "micMuteInMenuBar") as? Bool ?? true
        if wanted, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.action = #selector(statusClicked)
            item.button?.target = self
            statusItem = item
            updateIcon()
        } else if !wanted, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func statusClicked() { toggle() }

    private func updateIcon() {
        let name = muted ? "mic.slash.fill" : "mic.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Microphone")
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = muted ? .systemRed : nil
    }

    private func apply(_ on: Bool) {
        for device in Self.inputDevices() {
            Self.applyMute(on, to: device, saved: &savedVolumes)
        }
    }

    private static let deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func observeDeviceList() {
        var address = Self.deviceListAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.muted else { return }
                self.apply(true)
            }
        }
        deviceListListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    static func inputDevices() -> [AudioDeviceID] {
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

    private static func applyMute(
        _ on: Bool, to device: AudioDeviceID, saved: inout [AudioDeviceID: [UInt32: Float]]
    ) {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var mute = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeInput, mElement: element)
            if AudioObjectHasProperty(device, &mute) {
                var settable: DarwinBoolean = false
                if AudioObjectIsPropertySettable(device, &mute, &settable) == noErr,
                    settable.boolValue
                {
                    var value: UInt32 = on ? 1 : 0
                    AudioObjectSetPropertyData(
                        device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
                    return
                }
            }
        }
        applyVolumeFallback(on, to: device, saved: &saved)
    }

    private static func applyVolumeFallback(
        _ on: Bool, to device: AudioDeviceID, saved: inout [AudioDeviceID: [UInt32: Float]]
    ) {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var volume = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeInput, mElement: element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &volume),
                AudioObjectIsPropertySettable(device, &volume, &settable) == noErr,
                settable.boolValue
            else { continue }
            if on {
                var current: Float = 0
                var size = UInt32(MemoryLayout<Float>.size)
                if AudioObjectGetPropertyData(device, &volume, 0, nil, &size, &current) == noErr {
                    saved[device, default: [:]][element] = current
                }
                var zero: Float = 0
                AudioObjectSetPropertyData(
                    device, &volume, 0, nil, UInt32(MemoryLayout<Float>.size), &zero)
            } else if var restore = saved[device]?[element] {
                AudioObjectSetPropertyData(
                    device, &volume, 0, nil, UInt32(MemoryLayout<Float>.size), &restore)
            }
        }
    }
}
