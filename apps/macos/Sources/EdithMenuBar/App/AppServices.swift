import EdithKit
import Foundation

@MainActor
final class AppServices: ObservableObject {
    @Published private(set) var usage: UsageStore?
    @Published private(set) var music: MusicPlayer?
    @Published private(set) var system: SystemStore?
    @Published private(set) var calendar: CalendarStore?
    @Published private(set) var clipboard: ClipboardStore?

    static func tabEnabled(_ key: String) -> Bool {
        SharedDefaults.store.object(forKey: key) as? Bool ?? true
    }

    init() {
        sync()
    }

    func sync() {
        let usageOn = Self.tabEnabled("tabUsageEnabled")
        let musicOn = Self.tabEnabled("tabMusicEnabled")

        if usageOn, usage == nil { usage = UsageStore() }
        if !usageOn, let store = usage {
            store.shutdown()
            usage = nil
        }
        if musicOn, music == nil { music = MusicPlayer() }
        if !musicOn, let player = music {
            player.shutdown()
            music = nil
        }

        let systemOn = Self.tabEnabled("tabSystemEnabled")
        if systemOn, system == nil { system = SystemStore() }
        if !systemOn, let store = system {
            store.shutdown()
            system = nil
        }

        let calendarOn = Self.tabEnabled("tabCalendarEnabled")
        if calendarOn, calendar == nil { calendar = CalendarStore() }
        if !calendarOn, let store = calendar {
            store.shutdown()
            calendar = nil
        }

        let clipboardOn = SharedDefaults.store.object(forKey: "clipboardEnabled") as? Bool ?? false
        if clipboardOn, clipboard == nil { clipboard = ClipboardStore() }
        if !clipboardOn, let store = clipboard {
            store.shutdown()
            clipboard = nil
        }
        ClipboardPanel.shared.store = clipboard
    }
}
