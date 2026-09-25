import AppKit
import ApplicationServices
import EdithKit
import Foundation
import Observation

enum AttentionPageSection: String, CaseIterable, Identifiable {
    case overview
    case timeline
    case breakdown
    case agents
    case focus
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .timeline: "Timeline"
        case .breakdown: "Breakdown"
        case .agents: "Agents"
        case .focus: "Focus"
        case .settings: "Settings"
        }
    }

    var usesPeriod: Bool { self != .settings }
}

enum AttentionScope: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "30 days"
        }
    }

    var days: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        }
    }

    var previousTitle: String {
        switch self {
        case .day: "the day before"
        case .week: "the week before"
        case .month: "the 30 days before"
        }
    }
}

struct AttentionPeriod: Equatable {
    var scope: AttentionScope
    var anchor: Date

    init(scope: AttentionScope = .day, anchor: Date = Date(), calendar: Calendar = .current) {
        self.scope = scope
        self.anchor = calendar.startOfDay(for: anchor)
    }

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let end = calendar.date(byAdding: .day, value: 1, to: anchor) ?? anchor
        let start = calendar.date(byAdding: .day, value: 1 - scope.days, to: anchor) ?? anchor
        return DateInterval(start: start, end: max(start, min(end, now)))
    }

    var comparePeriod: TimeInterval { TimeInterval(scope.days) * 86_400 }

    func isCurrent(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.isDate(anchor, inSameDayAs: now)
    }

    func shifted(by steps: Int, calendar: Calendar = .current) -> AttentionPeriod {
        var next = self
        next.anchor =
            calendar.date(byAdding: .day, value: steps * scope.days, to: anchor) ?? anchor
        return next
    }

    func title(now: Date = Date(), calendar: Calendar = .current) -> String {
        let interval = interval(now: now, calendar: calendar)
        switch scope {
        case .day:
            if calendar.isDateInToday(anchor) { return "Today" }
            if calendar.isDateInYesterday(anchor) { return "Yesterday" }
            return anchor.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week, .month:
            let last = calendar.date(byAdding: .day, value: scope.days - 1, to: interval.start)
            let from = interval.start.formatted(.dateTime.month(.abbreviated).day())
            let to = (last ?? anchor).formatted(.dateTime.month(.abbreviated).day())
            return "\(from) to \(to)"
        }
    }
}

@MainActor
@Observable
final class AttentionPageModel {
    var section: AttentionPageSection = .overview
    var period = AttentionPeriod()
    var settings = AttentionSettings()
    var summary: AttentionSummary
    var focusSessions: [AttentionFocusSession] = []
    var activeFocus: AttentionFocusSession?
    var classifications = AttentionClassifications()
    var browserConnected = false
    var extensionInstalled = false
    var message: String?
    var errorMessage: String?
    var breakdownDimension = AttentionDimension.entity
    var kindFilter: AttentionCategoryKind?
    var categoryFilter: String?
    var search = ""
    private(set) var loaded = false
    private(set) var hasStoredEvents = false
    private(set) var transferringBackup = false
    private(set) var categorizing = false

    private let repository: AttentionRepository
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0

    init(repository: AttentionRepository = AttentionRepository()) {
        self.repository = repository
        let interval = AttentionPeriod().interval()
        summary = AttentionSummary(from: interval.start, to: interval.end)
    }

    var needsSetup: Bool {
        !settings.trackingEnabled && !settings.browserTrackingEnabled && !hasStoredEvents
    }

    var hasActivity: Bool {
        !summary.entities.isEmpty || summary.idleDuration > 0 || !summary.agents.isEmpty
    }

    var refreshInterval: Duration {
        period.isCurrent() ? .seconds(period.scope == .day ? 15 : 60) : .seconds(300)
    }

    var cloudBackup: AttentionCloudBackup { AttentionCloudBackup() }

    func category(_ id: String) -> AttentionCategory { settings.category(id) }

    func setScope(_ scope: AttentionScope) {
        guard period.scope != scope else { return }
        period.scope = scope
        reload()
    }

    func step(_ steps: Int) {
        let next = period.shifted(by: steps)
        guard next.anchor <= Calendar.current.startOfDay(for: Date()) else { return }
        period = next
        reload()
    }

    func showToday() {
        period = AttentionPeriod(scope: period.scope)
        reload()
    }

    var canStepForward: Bool { !period.isCurrent() }

    func reload(preserveSettings: Bool = false) {
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let repository = repository
        let period = period
        let knownSettings = settings
        reloadTask = Task.detached { [weak self] in
            do {
                let state = try await AttentionPageModel.loadState(
                    repository: repository, period: period,
                    settings: preserveSettings ? knownSettings : nil)
                guard !Task.isCancelled else { return }
                await self?.publish(
                    state, preserveSettings: preserveSettings, generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.publishFailure(error.localizedDescription, generation: generation)
            }
        }
    }

    func waitForReload() async {
        await reloadTask?.value
    }

    private func publish(_ state: AttentionPageState, preserveSettings: Bool, generation: Int) {
        guard !Task.isCancelled, reloadGeneration == generation else { return }
        reloadTask = nil
        if !preserveSettings { settings = state.settings }
        summary = state.summary
        activeFocus = state.activeFocus
        focusSessions = state.focusSessions
        classifications = state.classifications
        hasStoredEvents = state.hasStoredEvents
        extensionInstalled = state.extensionInstalled
        loaded = true
        errorMessage = nil
    }

    private func publishFailure(_ message: String, generation: Int) {
        guard !Task.isCancelled, reloadGeneration == generation else { return }
        reloadTask = nil
        errorMessage = message
        loaded = true
    }

    nonisolated private static func loadState(
        repository: AttentionRepository, period: AttentionPeriod, settings: AttentionSettings?
    ) async throws -> AttentionPageState {
        let interval = period.interval()
        let request = AttentionSummaryRequest(
            from: interval.start, to: interval.end, settings: settings,
            comparePeriod: period.comparePeriod)
        let snapshot: AttentionPageSnapshot
        if repository.resolvedEventSink is AgentAttentionSink {
            snapshot = try await AttentionBackgroundClient.summary(request)
        } else {
            snapshot = AttentionPageSnapshot(request: request, repository: repository)
        }
        return AttentionPageState(
            settings: snapshot.settings, summary: snapshot.summary,
            activeFocus: snapshot.activeFocus, focusSessions: snapshot.focusSessions,
            classifications: snapshot.classifications,
            hasStoredEvents: snapshot.hasStoredEvents,
            extensionInstalled: FileManager.default.fileExists(
                atPath: AttentionExtensionInstaller.installedDirectory.path))
    }

    func saveSettings() {
        do {
            settings.normalizeCategories()
            try repository.saveSettings(settings)
            IPC.post(IPC.Name.settingsChanged)
            message = "Settings saved"
            errorMessage = nil
            reload()
            Task { await checkBrowser() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeSetup(applicationTracking: Bool, browserTracking: Bool) {
        settings.isEnabled = applicationTracking || browserTracking
        settings.trackingEnabled = applicationTracking
        settings.browserTrackingEnabled = browserTracking
        saveSettings()
        section = .overview
    }

    func setAttentionEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        saveSettings()
    }

    func installExtension() {
        do {
            try AttentionExtensionInstaller.reveal()
            extensionInstalled = true
            message = "Extension folder ready"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openChromeExtensions() {
        guard let url = URL(string: "chrome://extensions") else { return }
        NSWorkspace.shared.open(url)
    }

    func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(settings.serverToken, forType: .string)
        message = "Private token copied"
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func startFocus(name: String, duration: TimeInterval) {
        do {
            activeFocus = try AttentionFocusOperationExecution.start(
                name: name, duration: duration, repository: repository)
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopFocus() {
        do {
            try AttentionFocusOperationExecution.stop(repository: repository)
            activeFocus = nil
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func assign(entity: AttentionEntity, to categoryID: String) {
        var next = settings
        guard next.assign(entityID: entity.id, categoryID: categoryID) != nil else { return }
        settings = next
        saveSettings()
    }

    func suggestion(for entity: AttentionEntity) -> AttentionJevDecision? {
        guard entity.categorySource == .jev || entity.isUnclassified else { return nil }
        if entity.categorySource == .jev, let confidence = entity.confidence {
            return AttentionJevDecision(categoryID: entity.category.id, confidence: confidence)
        }
        return nil
    }

    var triage: [AttentionEntity] {
        summary.entities.filter {
            ($0.isUnclassified || $0.categorySource == .jev) && $0.duration >= 60
        }
    }

    var quickCategories: [AttentionCategory] {
        let used = Dictionary(
            grouping: settings.rules, by: \.categoryID
        ).mapValues(\.count)
        return settings.categories.filter { $0.kind != .unclassified }
            .sorted { (used[$0.id] ?? 0) > (used[$1.id] ?? 0) }
    }

    func categorizeNow() {
        guard !categorizing else { return }
        categorizing = true
        Task { [weak self] in
            defer { self?.categorizing = false }
            do {
                let report = try await AttentionBackgroundClient.categorize()
                if report.available {
                    self?.message =
                        "Jev categorized \(report.entities) apps and sites and \(report.titles) titles"
                } else {
                    self?.message = "Add a Jev key in Settings to categorize automatically"
                }
                self?.errorMessage = nil
                self?.reload()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func addCategory() {
        settings.categories.append(
            AttentionCategory(
                id: "category-\(UUID().uuidString.lowercased())", name: "New category",
                kind: .neutral, color: "898781"))
    }

    func removeCategory(_ id: String) {
        guard settings.categories.count > 1,
            AttentionCatalog.categories.contains(where: { $0.id == id }) == false
        else { return }
        settings.categories.removeAll { $0.id == id }
        for index in settings.rules.indices where settings.rules[index].categoryID == id {
            settings.rules[index].categoryID = AttentionCatalog.unclassified
        }
    }

    func addRule() {
        settings.rules.insert(
            AttentionIdentityRule(name: "New rule", categoryID: "focus"), at: 0)
    }

    func removeRule(_ id: String) {
        settings.rules.removeAll { $0.id == id }
    }

    func backupNow() {
        guard !transferringBackup else { return }
        transferringBackup = true
        Task { [weak self] in
            defer { self?.transferringBackup = false }
            do {
                try await AttentionBackgroundClient.backup()
                self?.message = "Attention data backed up to iCloud Drive"
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func restoreBackup() {
        guard !transferringBackup else { return }
        transferringBackup = true
        Task { [weak self] in
            defer { self?.transferringBackup = false }
            do {
                try await AttentionBackgroundClient.restore()
                self?.message = "Attention backup restored"
                self?.errorMessage = nil
                self?.reload()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func checkBrowser() async {
        guard settings.isEnabled, settings.browserTrackingEnabled else {
            browserConnected = false
            return
        }
        browserConnected = await AttentionIngestionServer.isHealthy(port: settings.serverPort)
    }

    func filter(category id: String) {
        categoryFilter = id
        kindFilter = nil
        section = .breakdown
    }

    func matches(_ categories: [String: TimeInterval]) -> TimeInterval {
        if let categoryFilter { return categories[categoryFilter] ?? 0 }
        if let kindFilter {
            return categories.reduce(0) {
                settings.category($1.key).kind == kindFilter ? $0 + $1.value : $0
            }
        }
        return categories.values.reduce(0, +)
    }

    func matchesSearch(_ values: [String?]) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return values.contains { $0?.lowercased().contains(query) == true }
    }

    var hasFilters: Bool {
        kindFilter != nil || categoryFilter != nil
            || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func clearFilters() {
        kindFilter = nil
        categoryFilter = nil
        search = ""
    }
}

private struct AttentionPageState: Sendable {
    var settings: AttentionSettings
    var summary: AttentionSummary
    var activeFocus: AttentionFocusSession?
    var focusSessions: [AttentionFocusSession]
    var classifications: AttentionClassifications
    var hasStoredEvents: Bool
    var extensionInstalled: Bool
}
