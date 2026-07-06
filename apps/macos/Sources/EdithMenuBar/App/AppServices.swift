import EdithKit
import Foundation

@MainActor
final class AppServices: ObservableObject {
    @Published private(set) var usage: UsageStore?
    @Published private(set) var music: MusicPlayer?
    @Published private(set) var system: SystemStore?
    @Published private(set) var calendar: CalendarStore?
    @Published private(set) var colorPicker: ColorPickerStore?
    @Published private(set) var pixelRuler: PixelRulerStore?

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

        let colorPickerOn =
            SharedDefaults.store.object(forKey: "colorPickerEnabled") as? Bool ?? false
        if colorPickerOn, colorPicker == nil { colorPicker = ColorPickerStore() }
        if !colorPickerOn, let store = colorPicker {
            store.shutdown()
            colorPicker = nil
        }

        let pixelRulerOn =
            SharedDefaults.store.object(forKey: "pixelRulerEnabled") as? Bool ?? false
        if pixelRulerOn, pixelRuler == nil { pixelRuler = PixelRulerStore() }
        if !pixelRulerOn, let store = pixelRuler {
            store.shutdown()
            pixelRuler = nil
        }
    }
}
