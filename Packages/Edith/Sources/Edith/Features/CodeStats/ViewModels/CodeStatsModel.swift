import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class CodeStatsModel {
    static let shared = CodeStatsModel()

    private(set) var status: CodeStatsStatus?
    private(set) var report: CodeStatsReport?
    private(set) var projection = CodeStatsProjection()
    private(set) var reportLoaded = false
    var reportError: String? { reportLoad.errorMessage }
    private(set) var profileLookup: CodeStatsProfileLookup?
    private(set) var profileLoading = false
    private(set) var authors: [CodeStatsDiscoveredAuthor] = []
    private(set) var authorsLoading = false
    private(set) var identity: CodeStatsIdentity
    private(set) var isStarting = false
    private(set) var isCancelling = false
    var errorMessage: String?
    var range = CodeStatsRange.days(90)
    private(set) var table: CodeStatsFactTable?
    private(set) var audit: CodeStatsAudit?
    private(set) var filter = CodeStatsFilter.default
    var isComputing: Bool { computation.isRunning }
    private(set) var facets = CodeStatsFacets()
    private(set) var identityPendingRecount = false
    private(set) var explorer = CodeStatsExplorer()
    private(set) var lastPreset = CodeStatsRange.days(90)

    @ObservationIgnored private var reportRevision: UInt64 = 0
    @ObservationIgnored private let service: CodeStatsPageService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let today: @Sendable () -> Date
    let statusLoad = ContentLoad()
    let reportLoad = ContentLoad()
    let computation = ContentLoad()

    init(
        service: CodeStatsPageService = .live, defaults: UserDefaults = SharedDefaults.store,
        calendar: Calendar = .current, today: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.defaults = defaults
        self.calendar = calendar
        self.today = today
        identity = CodeStatsPreferences.identity(in: defaults)
        if let data = defaults.data(forKey: AppStorageKeys.CodeStats.pageSelection),
            let selection = try? JSONDecoder().decode(CodeStatsPageSelection.self, from: data)
        {
            filter = selection.filter
            range = selection.range
            lastPreset = selection.lastPreset
        }
    }

    var phase: CodeStatsPagePhase {
        CodeStatsPagePhase.resolve(
            status: status, hasReport: report != nil, reportLoaded: reportLoaded,
            reportFailed: reportError != nil)
    }

    var loadingState: ContentLoadingState {
        if report != nil { return .content }
        if status == nil { return statusLoad.state }
        if !reportLoaded { return reportLoad.state }
        switch phase {
        case .loading: return reportLoad.state == .content ? .loading : reportLoad.state
        case .firstRun: return .loading
        case .setup, .content: return .content
        case .unavailable: return .error
        }
    }

    var loadingError: String? { statusLoad.errorMessage ?? reportLoad.errorMessage }

    var isRefreshing: Bool {
        report != nil && (statusLoad.isRunning || reportLoad.isRunning || computation.isRunning)
    }

    func cancelLoading() {
        statusLoad.cancel()
        reportLoad.cancel()
        computation.cancel()
    }

    var showsPreviousRange: Bool {
        guard let report else { return false }
        return report.range != range
    }

    var isRunning: Bool { status?.isRunning ?? false }

    var progress: CodeStatsRunProgress? {
        guard let status, status.isRunning else { return nil }
        return status.progress
            ?? CodeStatsRunProgress(
                startedAt: status.state.active?.startedAt ?? Date())
    }

    var banners: [CodeStatsBanner] {
        guard let status else { return [] }
        switch phase {
        case .loading:
            return []
        case .setup:
            guard let lastRun = CodeStatsBanner.lastRun(status) else { return [] }
            return [lastRun]
        case .firstRun, .content, .unavailable:
            var banners = CodeStatsBanner.banners(for: status)
            if let reportError { banners.insert(CodeStatsBanner.report(reportError), at: 0) }
            return banners
        }
    }

    var canStart: Bool {
        guard let status else { return false }
        return status.storage.isReady && status.gitAvailable && !status.isRunning && !isStarting
    }

    var seededIdentity: CodeStatsIdentity? {
        guard identity.isEmpty, let lookup = profileLookup, let profile = lookup.profile else {
            return nil
        }
        return CodeStatsIdentity.seeded(login: profile.login, emails: lookup.emails)
    }

    var schedule: CodeStatsSchedule {
        status?.settings.schedule ?? CodeStatsPreferences.schedule(in: defaults)
    }

    func observe() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.followAgent() }
            group.addTask { await self.refresh() }
        }
    }

    func refresh() async {
        let revision = reportRevision
        await loadStatus()
        guard !Task.isCancelled, reportRevision == revision else { return }
        await loadReport()
    }

    func loadStatus() async {
        let request = statusLoad.begin()
        defer { if Task.isCancelled { statusLoad.cancel(request) } }
        do {
            let next = try await service.status()
            guard statusLoad.isCurrent(request) else { return }
            await apply(next)
            statusLoad.complete(request)
        } catch {
            statusLoad.fail(request, error: error)
        }
    }

    func loadReport() async {
        let request = reportLoad.begin()
        defer { if Task.isCancelled { reportLoad.cancel(request) } }
        let requested = range
        let calendar = calendar
        do {
            if let facts = try await service.facts() {
                let options = await Task.detached(priority: .userInitiated) {
                    CodeStatsFacets(table: facts)
                }.value
                guard reportLoad.isCurrent(request) else { return }
                table = facts
                facets = options
                await recompute()
                guard reportLoad.isCurrent(request) else { return }
                reportLoaded = true
                reportRevision &+= 1
                reportLoad.complete(request)
                return
            }
            let next = try await service.report(requested)
            let projected = await Task.detached(priority: .userInitiated) {
                next.map { CodeStatsProjection(report: $0, calendar: calendar) }
            }.value
            guard reportLoad.isCurrent(request) else { return }
            report = next
            projection = projected ?? CodeStatsProjection()
            reportLoaded = true
            reportRevision &+= 1
            reportLoad.complete(request)
        } catch {
            reportLoad.fail(request, error: error)
        }
    }

    func select(_ next: CodeStatsRange) async {
        guard next != range else { return }
        if CodeStatsRange.presets.contains(next) { lastPreset = next }
        range = next
        saveSelection()
        if table != nil {
            await recompute()
        } else {
            await loadReport()
        }
    }

    var hasActiveFilter: Bool { filter != .default }

    func updateFilter(_ change: (inout CodeStatsFilter) -> Void) async {
        var next = filter
        change(&next)
        guard next != filter else { return }
        filter = next
        saveSelection()
        await recompute()
    }

    func toggleRepository(_ name: String) async {
        await updateFilter { $0.repositories.formSymmetricDifference([name]) }
    }

    func toggleExcludedRepository(_ name: String) async {
        await updateFilter {
            $0.excludedRepositories.formSymmetricDifference([name])
            $0.repositories.remove(name)
        }
    }

    func zoom(from start: Date, to end: Date) async {
        let lower = CodeStatsDay(date: min(start, end), calendar: calendar)
        let upper = CodeStatsDay(date: max(start, end), calendar: calendar)
        await select(.between(lower.string, upper.string))
    }

    func clearCustomRange() async {
        await select(lastPreset)
    }

    var isCustomRange: Bool {
        if case .between = range { return true }
        return false
    }

    func toggleLanguage(_ name: String) async {
        await updateFilter { $0.languages.formSymmetricDifference([name]) }
    }

    func toggleOwner(_ name: String) async {
        await updateFilter { $0.owners.formSymmetricDifference([name]) }
    }

    func toggleCategory(_ category: CodeStatsCategory) async {
        await updateFilter { $0.categories.formSymmetricDifference([category]) }
    }

    func resetFilter() async {
        await updateFilter { $0 = .default }
    }

    func homeSummary() async -> CodeStatsHomeSummary? {
        guard let table else { return nil }
        let calendar = calendar
        let now = today()
        return await Task.detached(priority: .utility) {
            let month = CodeStatsReportBuilder.build(
                table: table, filter: .default, range: .days(30), today: now, calendar: calendar)
            let history = CodeStatsReportBuilder.build(
                table: table, filter: .default, range: .days(CodeStatsHomeSummary.heatDays),
                today: now, calendar: calendar)
            let explorer = CodeStatsExplorer(
                table: table, filter: .default, startDay: history.startDay,
                endDay: history.endDay, calendar: calendar)
            return CodeStatsHomeSummary(
                totals: month.totals, momentum: month.momentum,
                topRepositories: Array(month.repositories.prefix(3)),
                weeks: CodeStatsProjection(report: history, calendar: calendar).heatWeeks,
                days: explorer.days)
        }.value
    }

    func recompute() async {
        guard let table else { return }
        let filter = filter
        let range = range
        let calendar = calendar
        let identity = identity
        let now = today()
        await computation.perform(operation: {
            try await Task.sleep(for: .milliseconds(60))
            try Task.checkCancellation()
            let report = CodeStatsReportBuilder.build(
                table: table, filter: filter, range: range, today: now, calendar: calendar)
            return (
                report, CodeStatsProjection(report: report, calendar: calendar),
                CodeStatsAuditBuilder.build(table: table, filter: filter).matching(identity),
                CodeStatsExplorer(
                    table: table, filter: filter, startDay: report.startDay,
                    endDay: report.endDay, calendar: calendar)
            )
        }) { result in
            report = result.0
            projection = result.1
            audit = result.2
            explorer = result.3
        }
    }

    func apply(_ next: CodeStatsStatus) async {
        let previous = status
        guard next.revision >= previous?.revision ?? 0 else { return }
        status = next
        if !statusLoad.isRunning, !statusLoad.hasContent { statusLoad.setContent() }
        identity = next.settings.identity
        let finished = previous?.isRunning == true && !next.isRunning
        if finished { identityPendingRecount = false }
        let reported = previous?.state.reportedAt != next.state.reportedAt
        if finished || (previous != nil && reported) {
            await loadReport()
        }
    }

    func start() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            _ = try await service.start()
            await loadStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() async {
        guard !isCancelling else { return }
        isCancelling = true
        defer { isCancelling = false }
        do {
            await apply(try await service.cancel())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadProfileIfNeeded() async {
        guard profileLookup?.profile == nil else { return }
        await loadProfile()
    }

    func loadProfile() async {
        guard !profileLoading else { return }
        profileLoading = true
        defer { profileLoading = false }
        do {
            profileLookup = try await service.profile()
        } catch {
            profileLookup = CodeStatsProfileLookup(
                issue: .failed(message: error.localizedDescription))
        }
    }

    func discoverAuthors() async {
        guard !authorsLoading else { return }
        authorsLoading = true
        defer { authorsLoading = false }
        do {
            authors = try await service.authors()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseFolder(_ path: String) async {
        do {
            _ = try CodeStatsPreferences.selectFolder(path, defaults: defaults)
            await loadStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func useSeededIdentity() {
        guard let seededIdentity else { return }
        CodeStatsPreferences.setIdentity(seededIdentity, in: defaults)
        identity = seededIdentity
    }

    func addIdentity(_ value: String) {
        CodeStatsPreferences.addIdentity(value, in: defaults)
        identity = CodeStatsPreferences.identity(in: defaults)
        identityPendingRecount = true
        authors = CodeStatsAuthorMarking.marked(authors, identity: identity)
    }

    func removeIdentity(_ value: String) {
        CodeStatsPreferences.removeIdentity(value, in: defaults)
        identity = CodeStatsPreferences.identity(in: defaults)
        authors = CodeStatsAuthorMarking.marked(authors, identity: identity)
    }

    func setSchedule(_ kind: CodeStatsScheduleKind) async {
        let hour = defaults.object(forKey: AppStorageKeys.CodeStats.scheduleHour) as? Int
        let weekday = defaults.object(forKey: AppStorageKeys.CodeStats.scheduleWeekday) as? Int
        let next: CodeStatsSchedule
        switch kind {
        case .manual: next = .manual
        case .daily: next = .daily(hour: hour ?? CodeStatsPreferences.defaultHour)
        case .weekly:
            next = .weekly(
                weekday: weekday ?? CodeStatsPreferences.defaultWeekday,
                hour: hour ?? CodeStatsPreferences.defaultHour)
        }
        CodeStatsPreferences.setSchedule(next, in: defaults)
        await loadStatus()
    }

    private func saveSelection() {
        let selection = CodeStatsPageSelection(filter: filter, range: range, lastPreset: lastPreset)
        if let data = try? JSONEncoder().encode(selection) {
            defaults.set(data, forKey: AppStorageKeys.CodeStats.pageSelection)
        }
    }

    private func followAgent() async {
        for await next in service.updates() {
            guard !Task.isCancelled else { return }
            await apply(next)
        }
    }
}

enum CodeStatsAuthorMarking {
    static func marked(
        _ authors: [CodeStatsDiscoveredAuthor], identity: CodeStatsIdentity
    ) -> [CodeStatsDiscoveredAuthor] {
        let matches = identity.matcher()
        return authors.map { author in
            var updated = author
            updated.countedAsYou = matches(author.name, author.email)
            return updated
        }
    }
}

private struct CodeStatsPageSelection: Codable {
    var filter: CodeStatsFilter
    var range: CodeStatsRange
    var lastPreset: CodeStatsRange
}
