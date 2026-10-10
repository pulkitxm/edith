import AppKit

public enum MenuBarTintMode: Equatable {
    case automatic
    case custom

    public init(preference: String?) {
        self = preference == "custom" ? .custom : .automatic
    }

    public func color(custom: NSColor?) -> NSColor {
        switch self {
        case .automatic: .labelColor
        case .custom: custom ?? .labelColor
        }
    }
}
