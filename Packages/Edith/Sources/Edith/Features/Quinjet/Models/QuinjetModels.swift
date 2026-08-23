import Foundation

struct QuinjetRemote: Equatable, Sendable {
    let machineID: UUID
    let machineName: String
    let target: String
    let controlPath: String
}

struct QuinjetProject: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let commonDir: String
    let worktrees: [QuinjetWorktree]

    var id: String { commonDir }

    var availableWorktrees: [QuinjetWorktree] {
        worktrees.filter(\.canOpen)
    }

    var defaultWorktree: QuinjetWorktree? {
        availableWorktrees.first(where: \.current) ?? availableWorktrees.first
    }

    func contains(path: String) -> Bool {
        worktrees.contains { $0.path == path }
    }
}

struct QuinjetWorktree: Codable, Equatable, Identifiable, Sendable {
    let path: String
    let head: String
    let branch: String?
    let current: Bool
    let bare: Bool
    let detached: Bool
    let locked: String?
    let prunable: String?

    var id: String { path }
    var canOpen: Bool { !bare && prunable == nil }

    var displayName: String {
        if let branch, !branch.isEmpty { return branch }
        if detached { return "Detached at \(String(head.prefix(8)))" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

enum QuinjetHostAction: Equatable, Sendable {
    static let oscCode = 6973

    case openNewTab
    case openWorktree

    init?(payload: String) {
        switch payload {
        case "quinjet;open-new-tab": self = .openNewTab
        case "quinjet;open-worktree": self = .openWorktree
        default: return nil
        }
    }
}

enum QuinjetClientError: Error, Equatable, LocalizedError {
    case notInstalled
    case commandFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Quinjet is not installed. Install it from the Extensions page."
        case let .commandFailed(message):
            return message.isEmpty ? "Quinjet could not load this workspace." : message
        case .invalidResponse:
            return "Quinjet returned project data in an unsupported format."
        }
    }
}
