import EdithKit
import Foundation

enum CodeStatsPagePhase: Equatable, Sendable {
    case loading
    case setup
    case firstRun
    case content
    case unavailable

    static func resolve(
        status: CodeStatsStatus?, hasReport: Bool, reportLoaded: Bool, reportFailed: Bool = false
    ) -> CodeStatsPagePhase {
        guard let status else { return .loading }
        if hasReport { return .content }
        if status.isRunning { return .firstRun }
        if status.state.reportedAt != nil, reportFailed { return .unavailable }
        if status.state.reportedAt != nil, !reportLoaded { return .loading }
        return .setup
    }
}

enum CodeStatsBannerTone: Sendable {
    case warning
    case danger
}

struct CodeStatsBanner: Identifiable, Equatable, Sendable {
    let id: String
    let symbol: String
    let title: String
    let message: String
    var command: String?
    var choosesFolder = false
    var retriesReport = false
    var tone = CodeStatsBannerTone.warning

    static func banners(for status: CodeStatsStatus) -> [CodeStatsBanner] {
        var banners: [CodeStatsBanner] = []
        if let lastRun = lastRun(status) { banners.append(lastRun) }
        if let storage = storage(status) { banners.append(storage) }
        if !status.gitAvailable {
            banners.append(
                CodeStatsBanner(
                    id: "git", symbol: "hammer", title: "git is missing",
                    message: "Code Stats needs git to mirror and read repositories.",
                    command: "ed tools install git", tone: .danger))
        }
        let github = status.githubAvailable ? status.githubIssue : .unavailable
        if let github { banners.append(Self.github(github)) }
        return banners
    }

    static func lastRun(_ status: CodeStatsStatus) -> CodeStatsBanner? {
        guard !status.isRunning, let run = status.state.lastRun,
            run.finishedAt > status.state.reportedAt ?? .distantPast
        else { return nil }
        let firstError = run.errors.first.map { " " + $0 } ?? ""
        switch run.outcome {
        case .failed(let message):
            return CodeStatsBanner(
                id: "lastRun", symbol: "exclamationmark.octagon",
                title: "The last refresh failed", message: message + firstError, tone: .danger)
        case .interrupted:
            return CodeStatsBanner(
                id: "lastRun", symbol: "exclamationmark.arrow.circlepath",
                title: "The last refresh stopped early",
                message:
                    "Edith stopped before the refresh finished. Repositories it finished are kept; refresh to continue."
                    + firstError)
        default:
            return nil
        }
    }

    static func report(_ message: String) -> CodeStatsBanner {
        CodeStatsBanner(
            id: "report", symbol: "chart.bar.xaxis", title: "Results could not be loaded",
            message: message, retriesReport: true, tone: .danger)
    }

    static func github(_ issue: CodeStatsGitHubError) -> CodeStatsBanner {
        switch issue {
        case .unavailable:
            CodeStatsBanner(
                id: "github", symbol: "person.crop.circle.badge.questionmark",
                title: "GitHub CLI is not installed",
                message:
                    "Install gh to list and mirror your repositories. Repositories already in the folder are still counted.",
                command: "ed tools install gh")
        case .signedOut:
            CodeStatsBanner(
                id: "github", symbol: "person.crop.circle.badge.exclamationmark",
                title: "GitHub CLI is signed out",
                message:
                    "Sign in so Edith can list your repositories. Run this in Terminal, then refresh.",
                command: "gh auth login")
        case .failed(let message):
            CodeStatsBanner(
                id: "github", symbol: "exclamationmark.icloud", title: "GitHub could not be read",
                message: message)
        }
    }

    private static func storage(_ status: CodeStatsStatus) -> CodeStatsBanner? {
        switch status.storage {
        case .ready:
            return nil
        case .notConfigured:
            return CodeStatsBanner(
                id: "storage", symbol: "folder.badge.questionmark", title: "No mirror folder",
                message: status.storage.summary, choosesFolder: true)
        case .volumeDisconnected(let volume):
            let since = status.state.reportedAt.map {
                " Showing results from " + $0.formatted(date: .abbreviated, time: .shortened)
                    + "."
            }
            return CodeStatsBanner(
                id: "storage", symbol: "externaldrive.badge.xmark",
                title: "\(volume) is disconnected",
                message: "\(volume) is disconnected." + (since ?? "")
                    + " Reconnect it or choose another folder.",
                choosesFolder: true)
        case .missing, .notDirectory, .notWritable:
            return CodeStatsBanner(
                id: "storage", symbol: "folder.badge.minus", title: "Mirror folder unavailable",
                message: status.storage.summary, choosesFolder: true, tone: .danger)
        }
    }
}

extension CodeStatsPhase {
    var stepTitle: String {
        switch self {
        case .profile: "Profile"
        case .listing: "Repositories"
        case .syncing: "Sync"
        case .analyzing: "Analyze"
        case .reporting: "Report"
        }
    }
}

enum CodeStatsProgressMath {
    static let minimumFractionForEstimate = 0.03

    static func step(_ phase: CodeStatsPhase) -> Int {
        CodeStatsPhase.allCases.firstIndex(of: phase) ?? 0
    }

    static func elapsed(_ progress: CodeStatsRunProgress, now: Date) -> TimeInterval {
        max(now.timeIntervalSince(progress.startedAt), 0)
    }

    static func remaining(_ progress: CodeStatsRunProgress, now: Date) -> TimeInterval? {
        let fraction = min(max(progress.overallFraction, 0), 1)
        guard fraction >= minimumFractionForEstimate, fraction < 1 else { return nil }
        return elapsed(progress, now: now) * (1 - fraction) / fraction
    }

    static func repositories(_ progress: CodeStatsRunProgress) -> String? {
        guard [.syncing, .analyzing].contains(progress.phase), progress.total > 0 else {
            return nil
        }
        return "\(progress.completed) of \(progress.total) repositories"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \(seconds % 3_600 / 60)m"
    }
}
