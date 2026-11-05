import EdithIcons
import Foundation

enum SSHClipboardSyncState: Codable, Equatable, Sendable {
    case disabled
    case configuring
    case active
    case failed(String)

    var label: String {
        switch self {
        case .disabled: return "Clipboard sync disabled"
        case .configuring: return "Setting up clipboard sync"
        case .active: return "Clipboard sync active"
        case let .failed(message): return "Clipboard sync failed: \(message)"
        }
    }

    var icon: EdithIcon {
        switch self {
        case .disabled: return .clipboard
        case .configuring: return .sync
        case .active: return .clipboard
        case .failed: return .warning
        }
    }
}
