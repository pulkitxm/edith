import EdithKit
import Foundation

@MainActor
@Observable
final class AppServices {
    private(set) var usage: UsageStore?
    private(set) var music: MusicPlayer?
    private(set) var system: SystemStore?
    private(set) var calendar: CalendarStore?
    private(set) var notchShelf: NotchShelfController?
    private(set) var colorPicker: ColorPickerStore?
    private(set) var clipboard: ClipboardStore?
    private(set) var emoji: EmojiStore?
    private(set) var keystrokeHighlight: KeystrokeHighlightRuntime?
    private(set) var focusDim: FocusDimEngine?
    private(set) var presenter: PresenterDetector?
    private(set) var micMute: MicMuteEngine?
    private(set) var lidAwake: LidAwakeEngine?
    private(set) var systemStats: SystemStatsStatusItem?
    private(set) var attention: AttentionTrackingService?
    private let startup = StartupCoordinator()
    private let lidAwakeRestorationGate = LidAwakeRestorationGate()
    private let lidAwakeOrphanRestorer: @MainActor @Sendable () async -> LidAwakeOutcome
    private var lidAwakeRestorationError: String?
    private var terminating = false

    init(
        lidAwakeOrphanRestorer: @escaping @MainActor @Sendable () async -> LidAwakeOutcome = {
            await LidAwakeEngine.restoreOrphanedState()
        }
    ) {
        self.lidAwakeOrphanRestorer = lidAwakeOrphanRestorer
    }

    static func preferenceOnByDefault(_ key: String) -> Bool {
        SharedDefaults.store.object(forKey: key) as? Bool ?? true
    }

    static func attentionEnabled(
        extensionEnabled: Bool, settings: AttentionSettings
    ) -> Bool {
        extensionEnabled && settings.isEnabled
            && (settings.trackingEnabled || settings.browserTrackingEnabled)
    }

    static func extensionEnabled(_ key: String) -> Bool {
        SharedDefaults.store.object(forKey: key) as? Bool ?? false
    }

    static func audioMixerRuntimeEnabled(notchShelfEnabled: Bool, mixerEnabled: Bool) -> Bool {
        notchShelfEnabled && mixerEnabled
    }

    static func lidAwakeDisableRecovery(_ outcome: LidAwakeOutcome) -> String? {
        guard case .failed(let message) = outcome else { return nil }
        return message
    }

    static func lidAwakeRuntimeWanted(
        extensionEnabled: Bool, engineAvailable: Bool, restorationInFlight: Bool
    ) -> Bool {
        extensionEnabled && !engineAvailable && !restorationInFlight
    }

    static func lidAwakeRecoveryNeeded(
        _ defaults: UserDefaults = SharedDefaults.store
    ) -> Bool {
        LidAwakeState.restorationNeeded(defaults)
    }

    func start() {
        startup.start([
            StartupPhase(name: "helper.services.media") { [weak self] in
                self?.reconcileMediaServices()
            },
            StartupPhase(name: "helper.services.system") { [weak self] in
                self?.reconcileSystemServices()
            },
            StartupPhase(name: "helper.services.panels") { [weak self] in
                self?.reconcilePanelServices()
            },
            StartupPhase(name: "helper.services.presentation") { [weak self] in
                self?.reconcilePresentationServices()
            },
            StartupPhase(name: "helper.services.hardware") { [weak self] in
                self?.reconcileHardwareServices()
            },
            StartupPhase(name: "helper.services.status") { [weak self] in
                self?.reconcileStatusServices()
            },
            StartupPhase(name: "helper.services.attention") { [weak self] in
                self?.reconcileAttentionService()
            },
            StartupPhase(name: "helper.services.refresh") { [weak self] in
                self?.refreshServices()
            },
        ])
    }

    func prepareForTermination() async {
        startup.cancel()
        terminating = true
        shutDownEmojiRuntime()
        keystrokeHighlight?.shutdown()
        if #available(macOS 14.4, *) { MixerEngine.shared.shutdown() }
        await lidAwake?.shutdownForTermination()
        await lidAwakeRestorationGate.wait()
    }

    var lidAwakeRestorationInFlight: Bool {
        lidAwakeRestorationGate.isRestoring
    }

    func waitForLidAwakeRestoration() async -> LidAwakeOutcome? {
        await lidAwakeRestorationGate.waitForOutcome()
    }

    func disableLidAwakeExtension() async -> LidAwakeOutcome {
        if lidAwakeRestorationGate.isRestoring {
            return await lidAwakeRestorationGate.waitForOutcome()
                ?? .failed("The Lid Awake restoration did not finish.")
        }
        guard let engine = lidAwake else {
            guard Self.lidAwakeRecoveryNeeded() else {
                completeLidAwakeRecovery(.applied, disableExtensionOnSuccess: true)
                return .applied
            }
            return await recoverOrphanedLidAwake(disableExtensionOnSuccess: true)
        }
        let restoration = engine.uninstall()
        lidAwake = nil
        notchShelf?.attachLidAwake(nil)
        guard let restoration else {
            completeLidAwakeRecovery(.applied, disableExtensionOnSuccess: true)
            return .applied
        }
        lidAwakeRestorationGate.begin(restoration) { [weak self] outcome in
            self?.completeLidAwakeRecovery(outcome, disableExtensionOnSuccess: true)
        }
        return await lidAwakeRestorationGate.waitForOutcome()
            ?? .failed("The Lid Awake restoration did not finish.")
    }

    func recoverOrphanedLidAwake(
        disableExtensionOnSuccess: Bool = false
    ) async -> LidAwakeOutcome {
        beginOrJoinLidAwakeOrphanRecovery(
            disableExtensionOnSuccess: disableExtensionOnSuccess)
        return await lidAwakeRestorationGate.waitForOutcome()
            ?? .failed("The Lid Awake restoration did not finish.")
    }

    private func beginOrJoinLidAwakeOrphanRecovery(disableExtensionOnSuccess: Bool) {
        guard !lidAwakeRestorationGate.isRestoring else { return }
        let restoration = Task { @MainActor [lidAwakeOrphanRestorer] in
            await lidAwakeOrphanRestorer()
        }
        lidAwakeRestorationGate.begin(restoration) { [weak self] outcome in
            self?.completeLidAwakeRecovery(
                outcome, disableExtensionOnSuccess: disableExtensionOnSuccess)
        }
    }

    private func completeLidAwakeRecovery(
        _ outcome: LidAwakeOutcome, disableExtensionOnSuccess: Bool
    ) {
        guard let entry = LidAwakeOperationExecution.extensionEntry else { return }
        switch outcome {
        case .applied:
            lidAwakeRestorationError = nil
            if disableExtensionOnSuccess {
                _ = ExtensionMutationCenter().setEnabled(false, for: entry)
            }
        case .failed(let message):
            lidAwakeRestorationError = message
            _ = ExtensionMutationCenter().setEnabled(true, for: entry)
        }
        sync()
    }

    func sync() {
        guard !terminating else { return }
        startup.cancel()
        reconcileMediaServices()
        reconcileSystemServices()
        reconcilePanelServices()
        reconcilePresentationServices()
        reconcileHardwareServices()
        reconcileStatusServices()
        reconcileAttentionService()
        refreshServices()
    }

    func cancelStartup() {
        startup.cancel()
    }

    func waitForStartup() async {
        await startup.waitForCurrent()
    }

    private func reconcileMediaServices() {
        let usageState = Self.reconcileAgentUsageSettings()
        let usageOn = usageState.enabled
        let musicOn = Self.extensionEnabled(AppStorageKeys.Tabs.musicEnabled)

        if usageOn, usage == nil {
            SettingsBackup.shared.restoreDataOnEnable(for: .limits)
            SettingsBackup.shared.restoreDataOnEnable(for: .usage)
            usage = UsageStore()
        }
        if !usageOn, let store = usage {
            store.shutdown()
            usage = nil
        }
        if musicOn, music == nil {
            SettingsBackup.shared.restoreDataOnEnable(for: .music)
            music = MusicPlayer()
        }
        if !musicOn, let player = music {
            player.shutdown()
            music = nil
        }
    }

    private func reconcileSystemServices() {
        let systemOn = Self.extensionEnabled(AppStorageKeys.Tabs.systemEnabled)
        if systemOn, system == nil { system = SystemStore() }
        if !systemOn, let store = system {
            store.shutdown()
            system = nil
        }
        let sleepKeyOn = SharedDefaults.store.bool(forKey: AppStorageKeys.General.preventSleep)
        if sleepKeyOn,
            !FeatureGates.preventSleepPersisted(systemOn: systemOn, current: sleepKeyOn)
        {
            SharedDefaults.store.set(false, forKey: AppStorageKeys.General.preventSleep)
        }

        let calendarOn = Self.extensionEnabled(AppStorageKeys.Tabs.calendarEnabled)
        if calendarOn, calendar == nil { calendar = CalendarStore() }
        if !calendarOn, let store = calendar {
            store.shutdown()
            calendar = nil
        }
    }

    private func reconcilePanelServices() {
        let notchShelfOn = SharedDefaults.store.bool(forKey: AppStorageKeys.Notch.shelfEnabled)
        let audioMixerOn = SharedDefaults.store.bool(
            forKey: AppStorageKeys.Notch.audioMixerEnabled)
        if #available(macOS 14.4, *),
            !Self.audioMixerRuntimeEnabled(
                notchShelfEnabled: notchShelfOn, mixerEnabled: audioMixerOn)
        {
            MixerEngine.shared.shutdown()
        }
        if notchShelfOn, notchShelf == nil { notchShelf = NotchShelfController() }
        if !notchShelfOn, let controller = notchShelf {
            controller.shutdown()
            notchShelf = nil
        }
        notchShelf?.attachLocalMusic(music)

        let colorPickerOn =
            SharedDefaults.store.object(forKey: AppStorageKeys.ColorPicker.enabled) as? Bool
            ?? false
        if colorPickerOn, colorPicker == nil { colorPicker = ColorPickerStore() }
        if !colorPickerOn, let store = colorPicker {
            store.shutdown()
            colorPicker = nil
        }
        colorPicker?.registerHotKey()

        let clipboardOn =
            SharedDefaults.store.object(forKey: AppStorageKeys.Clipboard.enabled) as? Bool ?? false
        if clipboardOn {
            if clipboard == nil {
                SettingsBackup.shared.restoreDataOnEnable(for: .clipboard)
                clipboard = ClipboardStore()
            }
            ClipboardHotKey.register()
        } else {
            ClipboardHotKey.unregister()
            if let store = clipboard {
                store.shutdown()
                clipboard = nil
            }
        }
        ClipboardPanel.shared.store = clipboard

        let emojiOn = Self.extensionEnabled(AppStorageKeys.Emoji.enabled)
        if emojiOn {
            if emoji == nil { emoji = EmojiStore() }
            EmojiHotKey.register()
        } else {
            shutDownEmojiRuntime()
        }
        EmojiPanel.shared.store = emoji
        notchShelf?.attachClipboard(clipboard)
        notchShelf?.attachUsage(usage)
        notchShelf?.attachCalendar(calendar)
        notchShelf?.attachColorPicker(colorPicker)
    }

    private func shutDownEmojiRuntime() {
        EmojiHotKey.unregister()
        emoji?.shutdown()
        emoji = nil
        EmojiPanel.shared.store = nil
    }

    private func reconcilePresentationServices() {
        let keystrokeHighlightEnabled = Self.extensionEnabled(
            AppStorageKeys.KeystrokeHighlight.enabled)
        if keystrokeHighlightEnabled {
            KeystrokeHighlightHotKey.register()
        } else {
            KeystrokeHighlightHotKey.unregister()
            SharedDefaults.store.set(false, forKey: AppStorageKeys.KeystrokeHighlight.active)
        }
        let keystrokeHighlightWanted = FeatureGates.keystrokeHighlightMonitorWanted(
            enabled: keystrokeHighlightEnabled,
            active: SharedDefaults.store.bool(forKey: AppStorageKeys.KeystrokeHighlight.active))
        if keystrokeHighlightWanted, keystrokeHighlight == nil {
            keystrokeHighlight = KeystrokeHighlightRuntime()
        }
        if !keystrokeHighlightWanted, let runtime = keystrokeHighlight {
            runtime.shutdown()
            keystrokeHighlight = nil
        }
        keystrokeHighlight?.syncSettings()

        let focusDimOn = FocusDimState.isEnabled()
        if focusDimOn, focusDim == nil { focusDim = FocusDimEngine() }
        if !focusDimOn, let engine = focusDim {
            engine.shutdown()
            focusDim = nil
            FocusDimState.setActive(false)
        }

        let presenterExtensionOn = Self.extensionEnabled(AppStorageKeys.Presenter.enabled)
        PresenterState.shared.syncEnabled(presenterExtensionOn)
        if presenterExtensionOn {
            PresenterHotKey.register()
        } else {
            PresenterHotKey.unregister()
        }
        let presenterOn = FeatureGates.presenterDetectorWanted(
            presenterEnabled: presenterExtensionOn,
            autoEnabled: Self.extensionEnabled(AppStorageKeys.Presenter.autoEnabled))
        if presenterOn, presenter == nil { presenter = PresenterDetector() }
        if !presenterOn, let detector = presenter {
            detector.shutdown()
            presenter = nil
        }
    }

    private func reconcileHardwareServices() {
        let micOn = Self.extensionEnabled(AppStorageKeys.Mic.muteEnabled)
        if micOn, micMute == nil { micMute = MicMuteEngine() }
        if !micOn, let engine = micMute {
            engine.shutdown()
            micMute = nil
        }
        micMute?.syncSettings()

        reconcileLidAwakeService()
    }

    func reconcileLidAwakeService() {
        let lidAwakeOn = Self.extensionEnabled(LidAwakeState.enabledKey)
        if Self.lidAwakeRuntimeWanted(
            extensionEnabled: lidAwakeOn, engineAvailable: lidAwake != nil,
            restorationInFlight: lidAwakeRestorationGate.isRestoring)
        {
            lidAwake = LidAwakeEngine(initialError: lidAwakeRestorationError)
            lidAwakeRestorationError = nil
        }
        if !lidAwakeOn, let engine = lidAwake {
            let restoration = engine.uninstall()
            lidAwake = nil
            if let restoration {
                lidAwakeRestorationGate.begin(restoration) { [weak self] outcome in
                    guard let self else { return }
                    if let message = Self.lidAwakeDisableRecovery(outcome),
                        let entry = LidAwakeOperationExecution.extensionEntry
                    {
                        lidAwakeRestorationError = message
                        _ = ExtensionMutationCenter().setEnabled(true, for: entry)
                    }
                    sync()
                }
            }
        }
        if !lidAwakeOn, lidAwake == nil,
            Self.lidAwakeRecoveryNeeded(),
            !lidAwakeRestorationGate.isRestoring
        {
            beginOrJoinLidAwakeOrphanRecovery(disableExtensionOnSuccess: true)
        }
        notchShelf?.attachLidAwake(lidAwake)
    }

    private func reconcileStatusServices() {
        let statsOn = Self.extensionEnabled(AppStorageKeys.MenuBar.systemStats)
        if statsOn, systemStats == nil { systemStats = SystemStatsStatusItem() }
        if !statsOn, let stats = systemStats {
            stats.shutdown()
            systemStats = nil
        }
    }

    private func reconcileAttentionService() {
        let attentionSettings = AttentionRepository().loadSettings()
        let attentionOn = Self.attentionEnabled(
            extensionEnabled: Self.extensionEnabled(AppStorageKeys.Tabs.attentionEnabled),
            settings: attentionSettings)
        if attentionOn, attention == nil { attention = AttentionTrackingService() }
        if attentionOn { attention?.sync(attentionSettings) }
        if !attentionOn, let service = attention {
            service.shutdown()
            attention = nil
        }
    }

    private func refreshServices() {
        usage?.syncStatusItem()
        usage?.refreshMenuBarItem()
        notchShelf?.syncAlerts()
        notchShelf?.rebuildPanels()
        system?.syncPreventSleep()
        lidAwake?.refreshFromSystem()
        lidAwake?.syncSettings()
        focusDim?.applySettings()
        presenter?.applySettings()
    }

    private static func reconcileAgentUsageSettings() -> AgentUsageSettingsState {
        let defaults = SharedDefaults.store
        let state = AgentUsageSettingsFlow.providersChanged(
            AgentUsageSettingsState(
                enabled: extensionEnabled(AppStorageKeys.Tabs.usageEnabled),
                claudeEnabled: preferenceOnByDefault(AppStorageKeys.Limits.claudeEnabled),
                codexEnabled: preferenceOnByDefault(AppStorageKeys.Limits.codexEnabled),
                menuBarEnabled: preferenceOnByDefault(AppStorageKeys.Limits.inMenuBar),
                alertsEnabled: defaults.bool(forKey: AppStorageKeys.Notify.master),
                selectedProvider: LimitProvider(
                    rawValue: defaults.string(forKey: AppStorageKeys.Limits.provider) ?? "")
                    ?? .claude))
        let values = [
            AppStorageKeys.Tabs.usageEnabled: state.enabled,
            AppStorageKeys.Limits.inMenuBar: state.menuBarEnabled,
            AppStorageKeys.Notify.master: state.alertsEnabled,
        ]
        for (key, value) in values where defaults.bool(forKey: key) != value {
            defaults.set(value, forKey: key)
        }
        return state
    }
}
