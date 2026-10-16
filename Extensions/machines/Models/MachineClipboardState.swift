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

    var symbol: String {
        switch self {
        case .disabled: return "clipboard"
        case .configuring: return "arrow.triangle.2.circlepath"
        case .active: return "clipboard.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}
