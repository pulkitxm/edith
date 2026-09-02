import Foundation

public struct QuinjetRemote: Equatable, Sendable {
    public let machineID: UUID
    public let machineName: String
    public let target: String
    public let controlPath: String
    public let platform: RemoteMachinePlatform
    public let homeDirectory: String?
    public let executablePath: String?
    public let distributionID: String

    public init(
        machineID: UUID, machineName: String, target: String, controlPath: String,
        platform: RemoteMachinePlatform = .linux, homeDirectory: String? = nil,
        executablePath: String? = nil, distributionID: String? = nil
    ) {
        self.machineID = machineID
        self.machineName = machineName
        self.target = target
        self.controlPath = controlPath
        self.platform = platform
        self.homeDirectory = homeDirectory
        self.executablePath = executablePath
        self.distributionID = distributionID ?? platform.rawValue
    }

    public func resolve(_ path: String) -> String {
        QuinjetPath.resolve(path, homeDirectory: homeDirectory, platform: platform)
    }

    public static func connected(
        machineID: UUID, machineName: String, target: String, connection: SSHConnection
    ) async throws -> QuinjetRemote {
        let platform = await connection.remotePlatform ?? .linux
        let result = try? await connection.run(
            FilePlaces.homeDirectoryCommand(platform: platform), timeout: 20)
        let reportedHome =
            result?.succeeded == true
            ? result?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let home = reportedHome.flatMap { QuinjetPath.isAbsolute($0) ? $0 : nil }
        let executable = try await QuinjetRemoteExecutable.resolve(
            platform: platform, connection: connection)
        return QuinjetRemote(
            machineID: machineID, machineName: machineName, target: target,
            controlPath: connection.controlSocketPath, platform: platform,
            homeDirectory: home, executablePath: executable.path,
            distributionID: executable.distributionID)
    }
}

public enum QuinjetPath {
    public static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") || FileListing.isWindowsPath(path)
    }

    public static func resolve(
        _ path: String, homeDirectory: String?, platform: RemoteMachinePlatform
    ) -> String {
        guard let homeDirectory, !homeDirectory.isEmpty else { return path }
        if path == "~" { return homeDirectory }
        guard path.hasPrefix("~/") || path.hasPrefix("~\\") else { return path }
        let suffix = String(path.dropFirst(2))
        return FileListing.join(
            parent: homeDirectory,
            name: platform == .windows
                ? suffix.replacingOccurrences(of: "/", with: "\\") : suffix)
    }

    public static func name(_ path: String) -> String {
        (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
    }

    public static func equals(_ lhs: String, _ rhs: String) -> Bool {
        if FileListing.isWindowsPath(lhs) || FileListing.isWindowsPath(rhs) {
            return normalizedWindows(lhs).caseInsensitiveCompare(normalizedWindows(rhs))
                == .orderedSame
        }
        return lhs == rhs
    }

    public static func contains(_ path: String, in directory: String) -> Bool {
        if FileListing.isWindowsPath(path) || FileListing.isWindowsPath(directory) {
            let candidate = normalizedWindows(path)
            let parent = normalizedWindows(directory)
            return candidate.caseInsensitiveCompare(parent) == .orderedSame
                || candidate.lowercased().hasPrefix(parent.lowercased() + "\\")
        }
        return path == directory || path.hasPrefix(directory + "/")
    }

    private static func normalizedWindows(_ path: String) -> String {
        var result = path.replacingOccurrences(of: "/", with: "\\")
        while result.count > 3, result.hasSuffix("\\") { result.removeLast() }
        return result
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
        worktrees.contains { QuinjetPath.contains(path, in: $0.path) }
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
        return QuinjetPath.name(path)
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
    case remoteNotInstalled(
        machine: String, platform: RemoteMachinePlatform, distributionID: String)
    case launchFailed(String)
    case commandFailed(String)
    case invalidResponse

    public var isNotGitRepository: Bool {
        guard case let .commandFailed(message) = self else { return false }
        return message.localizedCaseInsensitiveContains("not a git repository")
    }

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Quinjet is not installed. Install it with `brew install pulkitxm/tap/quinjet`."
        case let .remoteNotInstalled(machine, platform, distributionID):
            let instruction =
                switch platform {
                case .darwin: "Install it there with `brew install pulkitxm/tap/quinjet`."
                case .windows: "Install it there with `winget install Pulkitxm.Quinjet`."
                case .linux where ["ubuntu", "debian"].contains(distributionID.lowercased()):
                    "Install it there from the Quinjet apt repository or with the shell installer."
                case .linux:
                    "Install it there with the Quinjet shell installer."
                }
            return "Quinjet is not installed on \(machine). \(instruction)"
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
