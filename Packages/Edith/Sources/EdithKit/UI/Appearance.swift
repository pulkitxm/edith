import AppKit

public func applyAppearance(_ value: String) {
    let app = NSApplication.shared
    switch value {
    case "light": app.appearance = NSAppearance(named: .aqua)
    case "dark": app.appearance = NSAppearance(named: .darkAqua)
    default: app.appearance = nil
    }
}
