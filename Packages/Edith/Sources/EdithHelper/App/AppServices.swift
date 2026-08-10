import EdithKit
import Foundation

@MainActor
@Observable
final class AppServices {
    private(set) var usage: UsageStore?
    private(set) var music: MusicPlayer?
    private(set) var system: SystemStore?
    private(set) var machines: MachineMonitor?
    private(set) var calendar: CalendarStore?
    private(set) var notchShelf: NotchShelfController?
    private(set) var colorPicker: ColorPickerStore?
    private(set) var clipboard: ClipboardStore?
    private(set) var focusDim: FocusDimEngine?
    private(set) var presenter: PresenterDetector?
    private(set) var micMute: MicMuteEngine?
    private(set) var systemStats: SystemStatsStatusItem?

    static func preferenceOnByDefault(_ key: String) -> Bool {
        SharedDefaults.store.object(forKey: key) as? Bool ?? true
    }

    static func extensionEnabled(_ key: String) -> Bool {
        SharedDefaults.store.object(forKey: key) as? Bool ?? false
    }

    init() {
        sync()
    }

    func sync() {
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

        let machinesOn = Self.extensionEnabled(AppStorageKeys.Tabs.machinesEnabled)
        if machinesOn, machines == nil { machines = MachineMonitor() }
        if !machinesOn, let monitor = machines {
            monitor.shutdown()
            machines = nil
        }

        let calendarOn = Self.extensionEnabled(AppStorageKeys.Tabs.calendarEnabled)
        if calendarOn, calendar == nil { calendar = CalendarStore() }
        if !calendarOn, let store = calendar {
            store.shutdown()
            calendar = nil
        }

        let notchShelfOn = SharedDefaults.store.bool(forKey: AppStorageKeys.Notch.shelfEnabled)
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
        notchShelf?.attachClipboard(clipboard)
        notchShelf?.attachUsage(usage)
        notchShelf?.attachCalendar(calendar)
        notchShelf?.attachColorPicker(colorPicker)

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

        let micOn = Self.extensionEnabled(AppStorageKeys.Mic.muteEnabled)
        if micOn, micMute == nil { micMute = MicMuteEngine() }
        if !micOn, let engine = micMute {
            engine.shutdown()
            micMute = nil
        }
        micMute?.syncSettings()

        let statsOn = Self.extensionEnabled(AppStorageKeys.MenuBar.systemStats)
        if statsOn, systemStats == nil { systemStats = SystemStatsStatusItem() }
        if !statsOn, let stats = systemStats {
            stats.shutdown()
            systemStats = nil
        }

        usage?.syncStatusItem()
        usage?.refreshMenuBarItem()
        usage?.notifier.clearStateIfMasterOff()
        notchShelf?.syncAlerts()
        notchShelf?.rebuildPanels()
        system?.syncPreventSleep()
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
