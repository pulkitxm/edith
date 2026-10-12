@testable import CodeStatsExtension
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

enum CodeStatsPageFixture {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static func date(_ day: String, hour: Int = 15) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return calendar.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
    }

    static var commits: [CodeStatsCommit] {
        [
            CodeStatsCommit(
                sha: "a1", day: "2026-09-28", hour: 9, repository: "octo/app",
                languages: ["Swift": .init(added: 40, updated: 5)]),
            CodeStatsCommit(
                sha: "a2", day: "2026-09-29", hour: 14, repository: "octo/app",
                languages: ["Swift": .init(added: 10)]),
            CodeStatsCommit(
                sha: "b1", day: "2026-09-30", hour: 22, repository: "octo/site",
                languages: ["TypeScript": .init(added: 120, updated: 30, deleted: 4)]),
            CodeStatsCommit(
                sha: "c1", day: "2026-08-15", hour: 11, repository: "octo/tools",
                languages: ["Python": .init(added: 7)]),
        ]
    }

    static func report(_ range: CodeStatsRange = .days(90)) -> CodeStatsReport {
        CodeStatsReportBuilder.build(
            commits: commits, range: range, today: date("2026-10-05"), calendar: calendar)
    }

    static func status(
        storage: CodeStatsStorageStatus = .ready(freeBytes: 500_000_000_000),
        reportedAt: Date? = nil, active: CodeStatsActiveRun? = nil,
        progress: CodeStatsRunProgress? = nil, waitingFor: String? = nil,
        gitAvailable: Bool = true, githubAvailable: Bool = true,
        github: CodeStatsGitHubError? = nil, lastRun: CodeStatsRunResult? = nil,
        revision: UInt64 = 0
    ) -> CodeStatsStatus {
        let lastRun =
            lastRun
            ?? github.map {
                CodeStatsRunResult(
                    outcome: .completed, startedAt: date("2026-10-01"),
                    finishedAt: date("2026-10-01"), github: $0)
            }
        return CodeStatsStatus(
            settings: CodeStatsSettings(folder: "/Volumes/Archive/GitHub"), storage: storage,
            gitAvailable: gitAvailable, githubAvailable: githubAvailable,
            state: CodeStatsState(
                lastRun: lastRun, lastRunAt: reportedAt, reportedAt: reportedAt, active: active,
                waitingFor: waitingFor),
            nextRunAt: nil, progress: progress, revision: revision)
    }
}

final class CodeStatsFakeAgent: @unchecked Sendable {
    private let lock = NSLock()
    private var currentStatus: CodeStatsStatus
    private var reports: [CodeStatsRange: CodeStatsReport]
    private var calls: [String] = []
    private var failing: Set<CodeStatsRange> = []
    private var table: CodeStatsFactTable?
    private var lookup = CodeStatsProfileLookup(
        profile: CodeStatsProfile(id: 7, login: "octo"), emails: ["octo@example.com"])
    private var discovered = [
        CodeStatsDiscoveredAuthor(
            name: "Octo", email: "octo@example.com", commits: 12, countedAsYou: false)
    ]
    let updates: AsyncStream<CodeStatsStatus>
    let updatesContinuation: AsyncStream<CodeStatsStatus>.Continuation

    init(status: CodeStatsStatus, reports: [CodeStatsRange: CodeStatsReport] = [:]) {
        currentStatus = status
        self.reports = reports
        (updates, updatesContinuation) = AsyncStream.makeStream(of: CodeStatsStatus.self)
    }

    var status: CodeStatsStatus {
        get { lock.withLock { currentStatus } }
        set { lock.withLock { currentStatus = newValue } }
    }

    func setReport(_ report: CodeStatsReport?, for range: CodeStatsRange) {
        lock.withLock { reports[range] = report }
    }

    var profileLookup: CodeStatsProfileLookup {
        get { lock.withLock { lookup } }
        set { lock.withLock { lookup = newValue } }
    }

    var authors: [CodeStatsDiscoveredAuthor] {
        get { lock.withLock { discovered } }
        set { lock.withLock { discovered = newValue } }
    }

    var failingReports: Set<CodeStatsRange> {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    var facts: CodeStatsFactTable? {
        get { lock.withLock { table } }
        set { lock.withLock { table = newValue } }
    }

    var recorded: [String] { lock.withLock { calls } }

    private func record(_ call: String) {
        lock.withLock { calls.append(call) }
    }

    var service: CodeStatsPageService {
        CodeStatsPageService(
            status: {
                self.record("status")
                return self.status
            },
            report: { range in
                self.record("report " + range.argument)
                if self.failingReports.contains(range) {
                    throw CodeStatsFailure(.unavailable, "The agent is restarting.")
                }
                return self.lock.withLock { self.reports[range] }
            },
            facts: {
                self.record("facts")
                return self.facts
            },
            start: {
                self.record("start")
                return CodeStatsActiveRun(trigger: .manual, startedAt: Date())
            },
            cancel: {
                self.record("cancel")
                return self.status
            },
            profile: {
                self.record("profile")
                return self.profileLookup
            },
            authors: {
                self.record("authors")
                return self.authors
            },
            updates: { self.updates })
    }
}
