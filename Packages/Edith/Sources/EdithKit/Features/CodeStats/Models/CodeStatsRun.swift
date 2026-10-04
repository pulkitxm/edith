import Foundation

public struct CodeStatsSettings: Codable, Equatable, Sendable {
    public var folder: String?
    public var identity: CodeStatsIdentity
    public var includeForks: Bool
    public var includeArchived: Bool
    public var schedule: CodeStatsSchedule

    public init(
        folder: String? = nil, identity: CodeStatsIdentity = CodeStatsIdentity(),
        includeForks: Bool = false, includeArchived: Bool = true,
        schedule: CodeStatsSchedule = .manual
    ) {
        self.folder = folder
        self.identity = identity
        self.includeForks = includeForks
        self.includeArchived = includeArchived
        self.schedule = schedule
    }

    public func includes(_ repository: CodeStatsRemoteRepository) -> Bool {
        (includeForks || !repository.isFork) && (includeArchived || !repository.isArchived)
    }
}

public enum CodeStatsPhase: String, Codable, CaseIterable, Sendable {
    case profile
    case listing
    case syncing
    case analyzing
    case reporting

    public var weight: Double {
        switch self {
        case .profile: 0.02
        case .listing: 0.03
        case .syncing: 0.55
        case .analyzing: 0.38
        case .reporting: 0.02
        }
    }
}

public struct CodeStatsRunProgress: Codable, Equatable, Sendable {
    public var phase: CodeStatsPhase = .profile
    public var startedAt: Date
    public var completed = 0
    public var total = 0
    public var inFlight: [String] = []
    public var synced = 0
    public var failed = 0
    public var skipped = 0
    public var listedKilobytes = 0
    public var phaseFraction = 0.0
    public var overallFraction = 0.0
    public var recentErrors: [String] = []

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }
}

public enum CodeStatsRunOutcome: Codable, Equatable, Sendable {
    case completed
    case cancelled
    case interrupted
    case volumeDisconnected(volumeName: String)
    case storageUnavailable(CodeStatsStorageStatus)
    case failed(message: String)

    public var isInterrupted: Bool {
        switch self {
        case .cancelled, .interrupted, .volumeDisconnected: true
        default: false
        }
    }
}

public struct CodeStatsRunResult: Codable, Equatable, Sendable {
    public var outcome: CodeStatsRunOutcome
    public var startedAt: Date
    public var finishedAt: Date
    public var profile: CodeStatsProfile?
    public var github: CodeStatsGitHubError?
    public var repositories: Int
    public var synced: Int
    public var failed: Int
    public var errors: [String]

    public init(
        outcome: CodeStatsRunOutcome, startedAt: Date, finishedAt: Date,
        profile: CodeStatsProfile? = nil, github: CodeStatsGitHubError? = nil,
        repositories: Int = 0, synced: Int = 0, failed: Int = 0, errors: [String] = []
    ) {
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.profile = profile
        self.github = github
        self.repositories = repositories
        self.synced = synced
        self.failed = failed
        self.errors = errors
    }
}
