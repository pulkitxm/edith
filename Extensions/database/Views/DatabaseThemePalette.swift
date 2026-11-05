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
    var canvas: Color { DashSkin.paper(dark, theme: theme) }
    var panel: Color { DashSkin.paper2(dark, theme: theme) }
    var ink: Color { DashSkin.ink(dark, theme: theme) }
    var inkSoft: Color { DashSkin.inkSoft(dark, theme: theme) }
    var inkFaint: Color { DashSkin.inkFaint(dark, theme: theme) }
    var line: Color { DashSkin.line(dark, theme: theme) }
    var lineStrong: Color { DashSkin.lineStrong(dark, theme: theme) }
    var grid: Color { DashSkin.grid(dark, theme: theme) }
}

struct DatabaseListSelectionHighlightRemoval: NSViewRepresentable {
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleRemoval()
        }

        func scheduleRemoval() {
            DispatchQueue.main.async { [weak self] in self?.removeHighlight() }
        }

        private func removeHighlight() {
            var ancestor = superview
            while let view = ancestor {
                if let table = table(in: view) {
                    table.selectionHighlightStyle = .none
                    return
                }
                ancestor = view.superview
            }
        }

        private func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews where child !== self {
                if let table = table(in: child) { return table }
            }
            return nil
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ anchor: Anchor, context: Context) { anchor.scheduleRemoval() }
}
