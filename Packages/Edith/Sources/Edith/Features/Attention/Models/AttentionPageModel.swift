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

    var part: AttentionSummaryPart {
        switch self {
        case .overview, .settings: .overview
        case .timeline: .timeline
        case .breakdown: .breakdown
        case .agents: .agents
        case .focus: .focus
        }
    }
}

@MainActor
@Observable
final class AttentionPageModel {
    var section: AttentionPageSection = .overview {
        didSet { if section != oldValue { ensurePart() } }
    }
    private(set) var period = AttentionPeriod()
    private(set) var window = AttentionTimeWindow.all
    var settings = AttentionSettings()
    private(set) var summary: AttentionSummary
    private(set) var dayRibbon: [AttentionRibbonBlock] = []
    private(set) var timeline: [AttentionTimelineDay] = []
    private(set) var triage: [AttentionEntity] = []
    var focusSessions: [AttentionFocusSession] = []
    var activeFocus: AttentionFocusSession?
    var classifications = AttentionClassifications()
    var browserConnected = false
    var extensionInstalled = false
    var message: String?
    var errorMessage: String?
    var breakdownDimension = AttentionDimension.entity
    private(set) var levelFilter: AttentionProductivity?
    private(set) var sphereFilter: AttentionSphere?
    private(set) var categoryFilter: String?
    private(set) var search = ""
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    private(set) var loaded = false
    private(set) var pending = false
    private(set) var hasStoredEvents = false
    private(set) var transferringBackup = false
    private(set) var categorizing = false

    private let repository: AttentionRepository
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var loadedParts: Set<AttentionSummaryPart> = []
    private var timelineTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(repository: AttentionRepository = AttentionRepository()) {
        self.repository = repository
        let interval = AttentionPeriod().interval()
        summary = AttentionSummary(from: interval.start, to: interval.end)
    }

    var needsSetup: Bool {
        !settings.trackingEnabled && !settings.browserTrackingEnabled && !hasStoredEvents
    }

    var hasActivity: Bool {
        !summary.categories.isEmpty || summary.idleDuration > 0 || !summary.agents.isEmpty
    }

    var refreshInterval: Duration {
        guard period.isCurrent() else { return .seconds(900) }
        return period.isSingleDay ? .seconds(30) : .seconds(120)
    }

    var cloudBackup: AttentionCloudBackup { AttentionCloudBackup() }

    func category(_ id: String) -> AttentionCategory { settings.category(id) }

    func select(_ preset: AttentionRangePreset) {
        setPeriod(AttentionPeriod(preset))
    }

    func selectRange(from: Date, to: Date) {
        setPeriod(AttentionPeriod.custom(from: from, to: to))
    }

    func step(_ steps: Int) {
        let next = period.shifted(by: steps)
        guard next.start <= Date() else { return }
        setPeriod(next)
    }

    func showToday() {
        setPeriod(AttentionPeriod(.today))
    }

    var canStepForward: Bool { !period.isCurrent() }

    func setPeriod(_ next: AttentionPeriod) {
        guard next != period else { return }
        period = next
        startLoading()
    }

    func setDays(_ weekdays: Set<Int>) {
        setWindow(
            AttentionTimeWindow(
                weekdays: weekdays, startHour: window.startHour, endHour: window.endHour))
    }

    func toggleDay(_ weekday: Int) {
        var days = window.allDays ? Set(1...7) : window.weekdays
        if days.contains(weekday) { days.remove(weekday) } else { days.insert(weekday) }
        guard !days.isEmpty else { return }
        setDays(days)
    }

    func setHours(start: Int, end: Int) {
        setWindow(AttentionTimeWindow(weekdays: window.weekdays, startHour: start, endHour: end))
    }

    func setWindow(_ next: AttentionTimeWindow) {
        guard next != window else { return }
        window = next
        startLoading()
    }

    private func startLoading() {
        loadedParts = []
        pending = true
        reload()
    }

    private func ensurePart() {
        guard loaded, !loadedParts.contains(section.part) else { return }
        pending = true
        reload()
    }

    func reload(preserveSettings: Bool = false) {
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let repository = repository
        let period = period
        let window = window
        let parts = loadedParts.union([section.part])
        let knownSettings = settings
        let current = summary
        let filter = spanFilter
        reloadTask = Task.detached { [weak self] in
            do {
                let state = try await AttentionPageModel.loadState(
                    repository: repository, period: period, window: window, parts: parts,
                    settings: preserveSettings ? knownSettings : nil, current: current,
                    filter: filter)
                guard !Task.isCancelled else { return }
                await self?.publish(
                    state, parts: parts, preserveSettings: preserveSettings,
                    generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.publishFailure(error.localizedDescription, generation: generation)
            }
        }
    }

    func waitForReload() async {
        await reloadTask?.value
        await timelineTask?.value
    }

    private func publish(
        _ state: AttentionPageState, parts: Set<AttentionSummaryPart>, preserveSettings: Bool,
        generation: Int
    ) {
        guard !Task.isCancelled, reloadGeneration == generation else { return }
        reloadTask = nil
        if !preserveSettings, settings != state.settings { settings = state.settings }
        if let derived = state.derived {
            summary = derived.summary
            dayRibbon = derived.dayRibbon
            timeline = derived.timeline
            triage = derived.triage
        }
        if activeFocus != state.activeFocus { activeFocus = state.activeFocus }
        if focusSessions != state.focusSessions { focusSessions = state.focusSessions }
        if classifications != state.classifications { classifications = state.classifications }
        hasStoredEvents = state.hasStoredEvents
        extensionInstalled = state.extensionInstalled
        loadedParts = parts
        loaded = true
        pending = false
        errorMessage = nil
    }

    private func publishFailure(_ message: String, generation: Int) {
        guard !Task.isCancelled, reloadGeneration == generation else { return }
        reloadTask = nil
        errorMessage = message
        loaded = true
        pending = false
    }

    nonisolated private static func loadState(
        repository: AttentionRepository, period: AttentionPeriod, window: AttentionTimeWindow,
        parts: Set<AttentionSummaryPart>, settings: AttentionSettings?,
        current: AttentionSummary, filter: AttentionSpanFilter
    ) async throws -> AttentionPageState {
        let interval = period.interval()
        let request = AttentionSummaryRequest(
            from: interval.start, to: interval.end, settings: settings,
            comparePeriod: period.comparePeriod, window: window, parts: parts)
        let snapshot: AttentionPageSnapshot
        if repository.resolvedEventSink is AgentAttentionSink {
            snapshot = try await AttentionBackgroundClient.summary(request)
        } else {
            snapshot = AttentionPageSnapshot(request: request, repository: repository)
                .trimmed(to: parts)
        }
        try Task.checkCancellation()
        let derived: AttentionPageDerivedState? =
            snapshot.summary == current
            ? nil
            : AttentionPageDerivedState(
                summary: snapshot.summary,
                dayRibbon: period.isSingleDay
                    ? AttentionPageDerived.dayRibbon(snapshot.summary) : [],
                timeline: parts.contains(.timeline)
                    ? AttentionPageDerived.timeline(snapshot.summary, filter: filter) : [],
                triage: triage(snapshot.summary))
        return AttentionPageState(
            settings: snapshot.settings, derived: derived,
            activeFocus: snapshot.activeFocus, focusSessions: snapshot.focusSessions,
            classifications: snapshot.classifications,
            hasStoredEvents: snapshot.hasStoredEvents,
            extensionInstalled: FileManager.default.fileExists(
                atPath: AttentionExtensionInstaller.installedDirectory.path))
    }

    var spanFilter: AttentionSpanFilter {
        AttentionSpanFilter(
            level: levelFilter, sphere: sphereFilter, category: categoryFilter, search: search)
    }

    private func refilterTimeline() {
        timelineTask?.cancel()
        guard loadedParts.contains(.timeline) else { return }
        let summary = summary
        let filter = spanFilter
        timelineTask = Task.detached(priority: .userInitiated) { [weak self] in
            let days = AttentionPageDerived.timeline(summary, filter: filter)
            guard !Task.isCancelled else { return }
            await self?.publishTimeline(days, filter: filter)
        }
    }

    private func publishTimeline(_ days: [AttentionTimelineDay], filter: AttentionSpanFilter) {
        guard filter == spanFilter else { return }
        timeline = days
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = searchText
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.searchText == text else { return }
            self.search = text
            self.refilterTimeline()
        }
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
        update(entity) { $0.assign(entityID: entity.id, categoryID: categoryID) }
    }

    func assign(entity: AttentionEntity, productivity: AttentionProductivity) {
        update(entity) {
            $0.assign(
                entityID: entity.id, productivity: productivity,
                fallbackCategoryID: entity.category.id)
        }
    }

    func assign(entity: AttentionEntity, sphere: AttentionSphere) {
        update(entity) {
            $0.assign(entityID: entity.id, sphere: sphere, fallbackCategoryID: entity.category.id)
        }
    }

    private func update(
        _ entity: AttentionEntity,
        _ change: (inout AttentionSettings) -> AttentionIdentityRule?
    ) {
        var next = settings
        guard change(&next) != nil else { return }
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

    var quickCategories: [AttentionCategory] { Self.quickCategories(settings) }

    nonisolated static func triage(_ summary: AttentionSummary) -> [AttentionEntity] {
        summary.entities.filter {
            ($0.isUnclassified || $0.categorySource == .jev) && $0.duration >= 60
        }
    }

    nonisolated static func quickCategories(_ settings: AttentionSettings) -> [AttentionCategory] {
        var used: [String: Int] = [:]
        for rule in settings.rules { used[rule.categoryID, default: 0] += 1 }
        let candidates = settings.categories.filter { !$0.isUnclassified }
        return candidates.sorted { (used[$0.id] ?? 0) > (used[$1.id] ?? 0) }
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
                id: "category-\(UUID().uuidString.lowercased())", name: "New category"))
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

    func filter(category id: String?, navigate: Bool = true) {
        clearSelection()
        categoryFilter = id
        refilterTimeline()
        if navigate { section = .breakdown }
    }

    func toggle(level: AttentionProductivity) {
        let active = levelFilter == level
        clearSelection()
        levelFilter = active ? nil : level
        refilterTimeline()
    }

    func toggle(sphere: AttentionSphere) {
        let active = sphereFilter == sphere
        clearSelection()
        sphereFilter = active ? nil : sphere
        refilterTimeline()
    }

    func matches(
        categories: [String: TimeInterval], levels: [String: TimeInterval],
        spheres: [String: TimeInterval]
    ) -> TimeInterval {
        if let categoryFilter { return categories[categoryFilter] ?? 0 }
        if let levelFilter { return levels[levelFilter.key] ?? 0 }
        if let sphereFilter { return spheres[sphereFilter.rawValue] ?? 0 }
        return Self.total(categories)
    }

    nonisolated static func total(_ values: [String: TimeInterval]) -> TimeInterval {
        var total: TimeInterval = 0
        for value in values.values { total += value }
        return total
    }

    func matchesSearch(_ values: [String?]) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return values.contains { $0?.lowercased().contains(query) == true }
    }

    var hasFilters: Bool {
        levelFilter != nil || sphereFilter != nil || categoryFilter != nil
            || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func clearSelection() {
        levelFilter = nil
        sphereFilter = nil
        categoryFilter = nil
    }

    func clearFilters() {
        clearSelection()
        searchTask?.cancel()
        searchText = ""
        search = ""
        refilterTimeline()
    }
}

private struct AttentionPageDerivedState: Sendable {
    var summary: AttentionSummary
    var dayRibbon: [AttentionRibbonBlock]
    var timeline: [AttentionTimelineDay]
    var triage: [AttentionEntity]
}

private struct AttentionPageState: Sendable {
    var settings: AttentionSettings
    var derived: AttentionPageDerivedState?
    var activeFocus: AttentionFocusSession?
    var focusSessions: [AttentionFocusSession]
    var classifications: AttentionClassifications
    var hasStoredEvents: Bool
    var extensionInstalled: Bool
}
