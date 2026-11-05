import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

private struct DatabaseAppThemeKey: EnvironmentKey {
    static var defaultValue: AppTheme { ThemeStore.current }
}

extension EnvironmentValues {
    var databaseAppTheme: AppTheme {
        get { self[DatabaseAppThemeKey.self] }
        set { self[DatabaseAppThemeKey.self] = newValue }
    }
}

struct DatabaseThemePalette {
    let dark: Bool
    let theme: AppTheme

    var accent: Color { DashSkin.accent(dark, theme: theme) }
    var canvas: Color { DashSkin.paper(dark) }
    var panel: Color { DashSkin.paper2(dark) }
    var ink: Color { DashSkin.ink(dark) }
    var inkSoft: Color { DashSkin.inkSoft(dark) }
    var inkFaint: Color { DashSkin.inkFaint(dark) }
    var line: Color { DashSkin.line(dark) }
    var lineStrong: Color { DashSkin.lineStrong(dark) }
    var grid: Color { DashSkin.grid(dark) }
}
