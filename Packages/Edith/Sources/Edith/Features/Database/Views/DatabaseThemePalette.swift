import EdithKit
import SwiftUI

private struct DatabaseAppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.accent
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
    var canvas: Color { DashSkin.paper(dark, theme: theme) }
    var panel: Color { DashSkin.paper2(dark, theme: theme) }
    var ink: Color { DashSkin.ink(dark, theme: theme) }
    var inkSoft: Color { DashSkin.inkSoft(dark, theme: theme) }
    var inkFaint: Color { DashSkin.inkFaint(dark, theme: theme) }
    var line: Color { DashSkin.line(dark, theme: theme) }
    var lineStrong: Color { DashSkin.lineStrong(dark, theme: theme) }
    var grid: Color { DashSkin.grid(dark, theme: theme) }
}
