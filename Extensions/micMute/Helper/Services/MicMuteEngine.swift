import AppKit
import CoreAudio
import EdithExtensionSupport
import EdithExtensionUI
import Observation
import SwiftUI

@MainActor
@Observable
final class MicMuteEngine: NSObject, FeatureModule {
    private(set) var muted = false

    private var stopped = false
    private let panel = StatusItemPanel()
    private let muting = MicrophoneMuteSession(access: CoreAudioMicrophones.access)
    private(set) var error: String?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var statusItem: NSStatusItem?

    override init() {
        super.init()
        muted = SharedDefaults.store.bool(forKey: AppStorageKeys.Mic.muted)
        if muted { apply(true) }
        observeDeviceList()
        syncSettings()
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        panel.close()
        HotKeyRegistrar.clear(HotKeyCatalog.micMute)
        apply(false)
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

    func retry() { if !stopped { apply(muted) } }

    func syncSettings() {
        HotKeyRegistrar.install(HotKeyCatalog.micMute) { [weak self] in self?.toggle() }
        updateStatusItemPresence()
    }

    func setMuted(_ on: Bool) {
        guard !stopped, on != muted else { return }
        muted = on
        SharedDefaults.store.set(on, forKey: AppStorageKeys.Mic.muted)
        apply(on)
        updateIcon()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    func updateStatusItemPresence() {
        let wanted =
            SharedDefaults.store.object(forKey: AppStorageKeys.Mic.muteInMenuBar) as? Bool ?? true
        if wanted, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            StatusItemMenu.attach(to: item, target: self, action: #selector(statusClicked))
            statusItem = item
            updateIcon()
        } else if !wanted, let item = statusItem {
            panel.close()
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func statusClicked() {
        guard let statusItem else { return }
        StatusItemMenu.handleClick(on: statusItem) {
            panel.show(
                from: statusItem, title: "Microphone",
                actions: [
                    .init(title: muted ? "Unmute microphone" : "Mute microphone") { [weak self] in
                        self?.toggle()
                    },
                    .init(title: "Open Edith…") { ExtensionPresentation.showWindow() },
                ]
            ) {
                Label(
                    muted ? "Microphone muted" : "Microphone on",
                    systemImage: muted ? "mic.slash.fill" : "mic.fill")
            }
        }
    }

    private func updateIcon() {
        let name = muted ? "mic.slash.fill" : "mic.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Microphone")
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = muted ? .systemRed : nil
    }

    private func apply(_ on: Bool) {
        error =
            muting.setMuted(on) ? nil : "Some microphone controls could not be changed. Try again."
    }

    private static let deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func observeDeviceList() {
        var address = Self.deviceListAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.stopped, self.muted else { return }
                self.apply(true)
            }
        }
        deviceListListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

}
