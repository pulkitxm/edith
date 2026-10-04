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
    private(set) var profileLookup: CodeStatsProfileLookup?
    private(set) var authors: [CodeStatsDiscoveredAuthor] = []
    private(set) var authorsLoading = false
    private(set) var identity: CodeStatsIdentity
    private(set) var isStarting = false
    private(set) var isCancelling = false
    var errorMessage: String?
    var range = CodeStatsRange.days(90)

    @ObservationIgnored private let service: CodeStatsPageService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var reportGeneration = 0
    @ObservationIgnored private var statusGeneration = 0

    init(
        service: CodeStatsPageService = .live, defaults: UserDefaults = SharedDefaults.store,
        calendar: Calendar = .current
    ) {
        self.service = service
        self.defaults = defaults
        self.calendar = calendar
        identity = CodeStatsPreferences.identity(in: defaults)
    }

    var phase: CodeStatsPagePhase {
        CodeStatsPagePhase.resolve(
            status: status, hasReport: report != nil, reportLoaded: reportLoaded)
    }

    var isRunning: Bool { status?.isRunning ?? false }

    var progress: CodeStatsRunProgress? {
        guard let status, status.isRunning else { return nil }
        return status.progress
            ?? CodeStatsRunProgress(
                startedAt: status.state.active?.startedAt ?? Date())
    }

    var banners: [CodeStatsBanner] {
        guard let status, ![.loading, .setup].contains(phase) else { return [] }
        return CodeStatsBanner.banners(for: status)
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
            group.addTask { await self.followVolumes() }
            group.addTask { await self.refresh() }
        }
    }

    func refresh() async {
        await loadStatus()
        await loadReport()
    }

    func loadStatus() async {
        statusGeneration += 1
        let generation = statusGeneration
        do {
            let next = try await service.status()
            guard generation == statusGeneration else { return }
            await apply(next)
        } catch {
            guard generation == statusGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadReport() async {
        reportGeneration += 1
        let generation = reportGeneration
        let requested = range
        let calendar = calendar
        do {
            let next = try await service.report(requested)
            let projected = await Task.detached(priority: .userInitiated) {
                next.map { CodeStatsProjection(report: $0, calendar: calendar) }
            }.value
            guard generation == reportGeneration else { return }
            report = next
            projection = projected ?? CodeStatsProjection()
            reportLoaded = true
        } catch {
            guard generation == reportGeneration else { return }
            reportLoaded = true
            errorMessage = error.localizedDescription
        }
    }

    func select(_ next: CodeStatsRange) async {
        guard next != range else { return }
        range = next
        await loadReport()
    }

    func apply(_ next: CodeStatsStatus) async {
        let previous = status
        guard next.revision >= previous?.revision ?? 0 else { return }
        status = next
        identity = next.settings.identity
        let finished = previous?.isRunning == true && !next.isRunning
        let reported = previous?.state.reportedAt != next.state.reportedAt
        if finished || (previous != nil && reported) {
            await loadReport()
        }
    }

    func volumesChanged() async {
        let wasWaiting = status?.state.waitingFor != nil
        await loadStatus()
        guard let status, status.storage.isReady, !status.isRunning else { return }
        guard wasWaiting || status.state.waitingFor != nil else { return }
        do {
            try await service.checkSchedule()
        } catch {
            errorMessage = error.localizedDescription
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

    func loadProfile() async {
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

    private func followAgent() async {
        for await next in service.updates() {
            guard !Task.isCancelled else { return }
            await apply(next)
        }
    }

    private func followVolumes() async {
        for await _ in service.volumeEvents() {
            guard !Task.isCancelled else { return }
            await volumesChanged()
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
