import EdithKit
import Foundation

@MainActor
final class AppServices: ObservableObject {
    @Published private(set) var usage: UsageStore?
    @Published private(set) var music: MusicPlayer?
    @Published private(set) var system: SystemStore?
    @Published private(set) var machines: MachineMonitor?
    @Published private(set) var calendar: CalendarStore?
    @Published private(set) var notchShelf: NotchShelfController?
    @Published private(set) var colorPicker: ColorPickerStore?
    @Published private(set) var clipboard: ClipboardStore?
    @Published private(set) var focusDim: FocusDimEngine?
    @Published private(set) var presenter: PresenterDetector?
    @Published private(set) var micMute: MicMuteEngine?
    @Published private(set) var systemStats: SystemStatsStatusItem?

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
        let musicOn = Self.extensionEnabled("tabMusicEnabled")

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

        let systemOn = Self.extensionEnabled("tabSystemEnabled")
        if systemOn, system == nil { system = SystemStore() }
        if !systemOn, let store = system {
            store.shutdown()
            system = nil
        }
        let sleepKeyOn = SharedDefaults.store.bool(forKey: "preventSleep")
        if sleepKeyOn,
            !FeatureGates.preventSleepPersisted(systemOn: systemOn, current: sleepKeyOn)
        {
            SharedDefaults.store.set(false, forKey: "preventSleep")
        }

        let machinesOn = Self.extensionEnabled("tabMachinesEnabled")
        if machinesOn, machines == nil { machines = MachineMonitor() }
        if !machinesOn, let monitor = machines {
            monitor.shutdown()
            machines = nil
        }

        let calendarOn = Self.extensionEnabled("tabCalendarEnabled")
        if calendarOn, calendar == nil { calendar = CalendarStore() }
        if !calendarOn, let store = calendar {
            store.shutdown()
            calendar = nil
        }

        let notchShelfOn = SharedDefaults.store.bool(forKey: "notchShelfEnabled")
        if notchShelfOn, notchShelf == nil { notchShelf = NotchShelfController() }
        if !notchShelfOn, let controller = notchShelf {
            controller.shutdown()
            notchShelf = nil
        }
        notchShelf?.attachLocalMusic(music)

        let colorPickerOn =
            SharedDefaults.store.object(forKey: "colorPickerEnabled") as? Bool ?? false
        if colorPickerOn, colorPicker == nil { colorPicker = ColorPickerStore() }
        if !colorPickerOn, let store = colorPicker {
            store.shutdown()
            colorPicker = nil
        }
        colorPicker?.registerHotKey()

        let clipboardOn = SharedDefaults.store.object(forKey: "clipboardEnabled") as? Bool ?? false
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

        let presenterExtensionOn = Self.extensionEnabled("presenterEnabled")
        PresenterState.shared.syncEnabled(presenterExtensionOn)
        if presenterExtensionOn {
            PresenterHotKey.register()
        } else {
            PresenterHotKey.unregister()
        }
        let presenterOn = FeatureGates.presenterDetectorWanted(
            presenterEnabled: presenterExtensionOn,
            autoEnabled: Self.extensionEnabled("presenterAutoEnabled"))
        if presenterOn, presenter == nil { presenter = PresenterDetector() }
        if !presenterOn, let detector = presenter {
            detector.shutdown()
            presenter = nil
        }

        let micOn = Self.extensionEnabled("micMuteEnabled")
        if micOn, micMute == nil { micMute = MicMuteEngine() }
        if !micOn, let engine = micMute {
            engine.shutdown()
            micMute = nil
        }
        micMute?.syncSettings()

        let statsOn = Self.extensionEnabled("menuBarSystemStats")
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
                enabled: extensionEnabled("tabUsageEnabled"),
                claudeEnabled: preferenceOnByDefault("claudeLimitsEnabled"),
                codexEnabled: preferenceOnByDefault("codexLimitsEnabled"),
                menuBarEnabled: preferenceOnByDefault("limitsInMenuBar"),
                alertsEnabled: defaults.bool(forKey: "notifyMaster"),
                selectedProvider: LimitProvider(
                    rawValue: defaults.string(forKey: "limitsProvider") ?? "") ?? .claude))
        let values = [
            "tabUsageEnabled": state.enabled,
            "limitsInMenuBar": state.menuBarEnabled,
            "notifyMaster": state.alertsEnabled,
        ]
        for (key, value) in values where defaults.bool(forKey: key) != value {
            defaults.set(value, forKey: key)
        }
        return state
    }
}
