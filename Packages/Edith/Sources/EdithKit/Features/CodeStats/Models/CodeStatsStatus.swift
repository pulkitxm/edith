import Foundation

public enum CodeStatsTrigger: String, Codable, Sendable {
    case manual
    case scheduled
}

public struct CodeStatsActiveRun: Codable, Equatable, Sendable {
    public var taskID: UUID
    public var trigger: CodeStatsTrigger
    public var startedAt: Date

    public init(taskID: UUID = UUID(), trigger: CodeStatsTrigger, startedAt: Date) {
        self.taskID = taskID
        self.trigger = trigger
        self.startedAt = startedAt
    }
}

public struct CodeStatsState: Codable, Equatable, Sendable {
    public var lastRun: CodeStatsRunResult?
    public var lastRunAt: Date?
    public var reportedAt: Date?
    public var profile: CodeStatsProfile?
    public var active: CodeStatsActiveRun?
    public var waitingFor: String?
    public var firstAttemptAt: Date?

    public init(
        lastRun: CodeStatsRunResult? = nil, lastRunAt: Date? = nil, reportedAt: Date? = nil,
        profile: CodeStatsProfile? = nil, active: CodeStatsActiveRun? = nil,
        waitingFor: String? = nil, firstAttemptAt: Date? = nil
    ) {
        self.lastRun = lastRun
        self.lastRunAt = lastRunAt
        self.reportedAt = reportedAt
        self.profile = profile
        self.active = active
        self.waitingFor = waitingFor
        self.firstAttemptAt = firstAttemptAt
    }

    public var scheduleBase: Date? { lastRunAt ?? firstAttemptAt }
}

public struct CodeStatsStatus: Codable, Equatable, Sendable {
    public var settings: CodeStatsSettings
    public var storage: CodeStatsStorageStatus
    public var gitAvailable: Bool
    public var githubAvailable: Bool
    public var state: CodeStatsState
    public var nextRunAt: Date?
    public var progress: CodeStatsRunProgress?
    public var revision: UInt64

    public init(
        settings: CodeStatsSettings, storage: CodeStatsStorageStatus, gitAvailable: Bool,
        githubAvailable: Bool, state: CodeStatsState, nextRunAt: Date?,
        progress: CodeStatsRunProgress?, revision: UInt64 = 0
    ) {
        self.settings = settings
        self.storage = storage
        self.gitAvailable = gitAvailable
        self.githubAvailable = githubAvailable
        self.state = state
        self.nextRunAt = nextRunAt
        self.progress = progress
        self.revision = revision
    }

    public var isRunning: Bool { state.active != nil }
    public var githubIssue: CodeStatsGitHubError? { state.lastRun?.github }
}

public struct CodeStatsProfileLookup: Codable, Equatable, Sendable {
    public var profile: CodeStatsProfile?
    public var emails: [String]
    public var issue: CodeStatsGitHubError?

    public init(
        profile: CodeStatsProfile? = nil, emails: [String] = [],
        issue: CodeStatsGitHubError? = nil
    ) {
        self.profile = profile
        self.emails = emails
        self.issue = issue
    }
}

public struct CodeStatsDiscoveredAuthor: Codable, Equatable, Sendable {
    public var name: String
    public var email: String
    public var commits: Int
    public var countedAsYou: Bool

    public init(name: String, email: String, commits: Int, countedAsYou: Bool) {
        self.name = name
        self.email = email
        self.commits = commits
        self.countedAsYou = countedAsYou
    }
}

extension CodeStatsStorageStatus {
    public var summary: String {
        switch self {
        case .notConfigured:
            "No mirror folder is chosen. Choose one with ed code-stats folder <path>."
        case .ready(let freeBytes):
            freeBytes.map {
                "Ready, "
                    + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " free"
            } ?? "Ready"
        case .volumeDisconnected(let volumeName):
            "\(volumeName) is disconnected. Reconnect it or choose another folder."
        case .missing: "The mirror folder no longer exists."
        case .notDirectory: "The mirror folder path is not a folder."
        case .notWritable: "Edith cannot write to the mirror folder."
        }
    }
}

extension CodeStatsGitHubError {
    public var state: String {
        switch self {
        case .unavailable: "unavailable"
        case .signedOut: "signedOut"
        case .failed: "failed"
        }
    }

    public var summary: String {
        switch self {
        case .unavailable:
            "The GitHub CLI is not installed. Install it with ed tools install gh, then run "
                + "gh auth login."
        case .signedOut: "The GitHub CLI is signed out. Run gh auth login."
        case .failed(let message): "GitHub could not be read: " + message
        }
    }
}

extension CodeStatsRunOutcome {
    public var summary: String {
        switch self {
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .interrupted: "interrupted"
        case .volumeDisconnected(let volumeName): "waiting for \(volumeName)"
        case .storageUnavailable(let storage): storage.summary
        case .failed(let message): message
        }
    }
}
