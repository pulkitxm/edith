import AppKit

enum MenuBarTintMode: Equatable {
    case automatic
    case custom

    init(preference: String?) {
        self = preference == "custom" ? .custom : .automatic
    }

    func color(custom: NSColor?) -> NSColor {
        switch self {
        case .automatic: .labelColor
        case .custom: custom ?? .labelColor
        }
    }
}
