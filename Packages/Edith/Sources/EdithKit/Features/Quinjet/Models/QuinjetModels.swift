import Foundation

public struct QuinjetRemote: Equatable, Sendable {
    public let machineID: UUID
    public let machineName: String
    public let target: String
    public let controlPath: String

    public init(machineID: UUID, machineName: String, target: String, controlPath: String) {
        self.machineID = machineID
        self.machineName = machineName
        self.target = target
        self.controlPath = controlPath
    }
}

public struct QuinjetRemoteFolder: Codable, Equatable, Sendable {
    public let target: String
    public let folder: String
    public let accessible: Bool
    public let uses: UInt64

    public init(target: String, folder: String, accessible: Bool, uses: UInt64) {
        self.target = target
        self.folder = folder
        self.accessible = accessible
        self.uses = uses
    }
}

public struct QuinjetRemoteFolders: Codable, Equatable, Sendable {
    public let remotes: [QuinjetRemoteFolder]

    public init(remotes: [QuinjetRemoteFolder]) {
        self.remotes = remotes
    }
}

public struct QuinjetProject: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let commonDir: String
    public let worktrees: [QuinjetWorktree]

    public init(name: String, commonDir: String, worktrees: [QuinjetWorktree]) {
        self.name = name
        self.commonDir = commonDir
        self.worktrees = worktrees
    }

    public var id: String { commonDir }

    public var availableWorktrees: [QuinjetWorktree] {
        worktrees.filter(\.canOpen)
    }

    public var defaultWorktree: QuinjetWorktree? {
        availableWorktrees.first(where: \.current) ?? availableWorktrees.first
    }

    public func contains(path: String) -> Bool {
        worktrees.contains { $0.path == path }
    }
}

public struct QuinjetWorktree: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let head: String
    public let branch: String?
    public let current: Bool
    public let bare: Bool
    public let detached: Bool
    public let locked: String?
    public let prunable: String?

    public init(
        path: String, head: String, branch: String?, current: Bool, bare: Bool,
        detached: Bool, locked: String?, prunable: String?
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.current = current
        self.bare = bare
        self.detached = detached
        self.locked = locked
        self.prunable = prunable
    }

    public var id: String { path }
    public var canOpen: Bool { !bare && prunable == nil }

    public var displayName: String {
        if let branch, !branch.isEmpty { return branch }
        if detached { return "Detached at \(String(head.prefix(8)))" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

public enum QuinjetHostAction: Equatable, Sendable {
    public static let oscCode = 6973

    case openNewTab
    case openWorktree

    public init?(payload: String) {
        switch payload {
        case "quinjet;open-new-tab": self = .openNewTab
        case "quinjet;open-worktree": self = .openWorktree
        default: return nil
        }
    }
}

public enum QuinjetClientError: Error, Equatable, LocalizedError {
    case notInstalled
    case launchFailed(String)
    case commandFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Quinjet is not installed. Install it with `brew install pulkitxm/tap/quinjet`."
        case let .launchFailed(message):
            return "Quinjet could not start: \(message)"
        case let .commandFailed(message):
            if message.localizedCaseInsensitiveContains("not a git repository") {
                return
                    "This folder is not a Git repository. "
                    + "Choose the project folder that contains .git."
            }
            return message.isEmpty ? "Quinjet could not load this workspace." : message
        case .invalidResponse:
            return "Quinjet returned project data in an unsupported format."
        }
    }
}

public struct QuinjetOpenSelection: Equatable, Sendable {
    public let projectName: String
    public let worktree: QuinjetWorktree
    public let worktrees: [QuinjetWorktree]

    public init(
        projectName: String, worktree: QuinjetWorktree, worktrees: [QuinjetWorktree]
    ) {
        self.projectName = projectName
        self.worktree = worktree
        self.worktrees = worktrees
    }
}

public enum QuinjetOperationError: Error, Equatable, LocalizedError {
    case noOpenWorktree(String)

    public var errorDescription: String? {
        switch self {
        case let .noOpenWorktree(path):
            return "No open worktree was found in \(path)."
        }
    }
}
