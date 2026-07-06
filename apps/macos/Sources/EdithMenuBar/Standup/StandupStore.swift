import AppKit
import EdithKit
import Foundation

@MainActor
final class StandupStore: ObservableObject, FeatureModule {
    @Published private(set) var running = false
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var lastError: String?

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var dayChangeObserver: NSObjectProtocol?
    private let notifier = StandupNotifier()

    init() {
        armTimer()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.runIfDue() }
        }
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.armTimer()
                self?.runIfDue()
            }
        }
        runIfDue()
    }

    func rearm() {
        armTimer()
        runIfDue()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let dayChangeObserver {
            NotificationCenter.default.removeObserver(dayChangeObserver)
            self.dayChangeObserver = nil
        }
    }

    private func armTimer() {
        timer?.invalidate()
        timer = nil
        let settings = StandupSettings.fromDefaults(SharedDefaults.store)
        guard settings.enabled else { return }
        var comps = DateComponents()
        comps.hour = settings.scheduleHour
        comps.minute = settings.scheduleMinute
        comps.second = 0
        guard
            let fire = Calendar.current.nextDate(
                after: Date(), matching: comps,
                matchingPolicy: .nextTimePreservingSmallerComponents)
        else { return }
        let t = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.runIfDue()
                self?.armTimer()
            }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func runIfDue(now: Date = Date()) {
        guard !running else { return }
        let settings = StandupSettings.fromDefaults(SharedDefaults.store)
        guard settings.enabled else { return }
        let lastRunDay = SharedDefaults.store.string(forKey: "standupLastRunDay")
        guard
            StandupSchedule.isDue(
                now: now, scheduledMinutesFromMidnight: settings.scheduleMinutesFromMidnight,
                lastRunDay: lastRunDay)
        else { return }
        running = true
        Task {
            await generate(settings: settings, now: now)
            running = false
        }
    }

    private func generate(settings: StandupSettings, now: Date) async {
        lastError = nil
        let range = StandupDateRange.range(today: now)
        let dayQuery = StandupDateRange.dayQuery(range)
        let repoRoots = settings.repoRoots

        let repos = await Task.detached(priority: .utility) {
            StandupRepoDiscovery.discover(roots: repoRoots)
        }.value

        var commits: [String] = []
        for repo in repos {
            commits.append(
                contentsOf: await StandupGathering.gitCommits(
                    repo: repo, author: settings.authorEmail, range: range))
        }

        var authoredPRs: [String] = []
        var reviewedPRs: [String] = []
        if let gh = await StandupBinaryLocator.resolve("gh") {
            authoredPRs = await StandupGathering.authoredPRs(
                ghPath: gh, dayQuery: dayQuery, allowlist: settings.githubAllowlist)
            reviewedPRs = await StandupGathering.reviewedPRs(
                ghPath: gh, dayQuery: dayQuery, allowlist: settings.githubAllowlist)
        }

        let notionLines = await gatherNotion(settings: settings, range: range)

        let context = StandupContext.build(
            commits: commits, authoredPRs: authoredPRs, reviewedPRs: reviewedPRs,
            notionRuns: notionLines)

        guard let claude = await StandupBinaryLocator.resolve("claude") else {
            lastError = "claude CLI not found"
            return
        }
        guard
            let text = await StandupGathering.synthesize(
                claudePath: claude, model: settings.model, context: context)
        else {
            lastError = "claude did not return a standup"
            return
        }

        SharedDefaults.store.set(StandupSchedule.dayKey(now), forKey: "standupLastRunDay")

        writeFile(text: text, date: now)
        if settings.deliverNotification {
            notifier.send(text: text, date: now)
        }
        lastRunAt = now
    }

    private func gatherNotion(settings: StandupSettings, range: StandupDateRange.Range) async
        -> [String]
    {
        guard !settings.notionDatabaseID.isEmpty, let token = StandupKeychain.get() else {
            return []
        }
        do {
            let dataSourceID = try await StandupNotionClient.resolveDataSourceID(
                databaseID: settings.notionDatabaseID, token: token)
            let data = try await StandupNotionClient.queryRuns(
                dataSourceID: dataSourceID, token: token,
                tagsProperty: settings.notionTagsProperty, workTag: settings.workTag)
            let rows = NotionRowParsing.parse(
                data, tagsProperty: settings.notionTagsProperty,
                dateProperty: settings.notionDateProperty)
            return NotionRowParsing.linesInRange(rows, since: range.since, until: range.until)
        } catch {
            return []
        }
    }

    private func writeFile(text: String, date: Date) {
        let url = StandupHistory.filePath(for: date)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = "# \(StandupSchedule.dayKey(date))\n\n"
        try? (header + text).write(to: url, atomically: true, encoding: .utf8)
    }
}
