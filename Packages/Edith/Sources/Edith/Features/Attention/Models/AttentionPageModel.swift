import AppKit
import ApplicationServices
import EdithKit
import Foundation
import Observation

enum AttentionPageSection: String, CaseIterable, Identifiable {
    case overview
    case timeline
    case focus
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .timeline: return "Timeline"
        case .focus: return "Focus"
        case .settings: return "Settings"
        }
    }
}

enum AttentionViewRange: String, CaseIterable, Identifiable {
    case today
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return DateInterval(start: today, end: now)
        case .week:
            return DateInterval(
                start: calendar.date(byAdding: .day, value: -6, to: today)!, end: now)
        case .month:
            return DateInterval(
                start: calendar.date(byAdding: .day, value: -29, to: today)!, end: now)
        }
    }
}

@MainActor
@Observable
final class AttentionPageModel {
    var section: AttentionPageSection = .overview
    var range: AttentionViewRange = .today
    var settings = AttentionSettings()
    var summary: AttentionSummary
    var events: [AttentionEvent] = []
    var focusSessions: [AttentionFocusSession] = []
    var activeFocus: AttentionFocusSession?
    var browserConnected = false
    var extensionInstalled = false
    var message: String?
    var errorMessage: String?
    private(set) var loaded = false
    private(set) var hasStoredEvents = false

    private let repository: AttentionRepository
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0

    init(repository: AttentionRepository = AttentionRepository()) {
        self.repository = repository
        let interval = AttentionViewRange.today.interval()
        summary = AttentionSummary(
            from: interval.start, to: interval.end, activeDuration: 0, idleDuration: 0,
            focusedDuration: 0, communicationDuration: 0, entertainmentDuration: 0,
            contextSwitches: 0, entities: [], music: [])
    }

    var needsSetup: Bool {
        !settings.trackingEnabled && !settings.browserTrackingEnabled && !hasStoredEvents
    }

    var hasActivity: Bool { !summary.entities.isEmpty || summary.idleDuration > 0 }

    var cloudBackup: AttentionCloudBackup { AttentionCloudBackup() }

    func reload(preserveSettings: Bool = false) {
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let repository = repository
        let range = range
        let knownSettings = settings
        reloadTask = Task.detached { [weak self] in
            let state = AttentionPageModel.loadState(
                repository: repository, range: range,
                settings: preserveSettings ? knownSettings : nil)
            await self?.publish(state, preserveSettings: preserveSettings, generation: generation)
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
        events = state.events
        activeFocus = state.activeFocus
        focusSessions = state.focusSessions
        hasStoredEvents = state.hasStoredEvents
        extensionInstalled = state.extensionInstalled
        loaded = true
    }

    nonisolated private static func loadState(
        repository: AttentionRepository, range: AttentionViewRange, settings: AttentionSettings?
    ) -> AttentionPageState {
        let resolvedSettings = settings ?? repository.loadSettings()
        let interval = range.interval()
        let all = repository.events(from: interval.start, to: interval.end)
        let summary = AttentionAnalyzer().summary(
            events: all, settings: resolvedSettings, from: interval.start, to: interval.end)
        let events = Array(all.sorted { $0.startedAt > $1.startedAt }.prefix(500))
        let focusSessions = Array(
            repository.focusSessions(from: interval.start, to: interval.end).reversed())
        return AttentionPageState(
            settings: resolvedSettings, summary: summary, events: events,
            activeFocus: repository.activeFocus(), focusSessions: focusSessions,
            hasStoredEvents: repository.hasEvents(),
            extensionInstalled: FileManager.default.fileExists(
                atPath: AttentionExtensionInstaller.installedDirectory.path))
    }

    func saveSettings() {
        do {
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
        if entity.id.hasPrefix("identity:") {
            let id = String(entity.id.dropFirst("identity:".count))
            guard let index = next.rules.firstIndex(where: { $0.id == id }) else { return }
            next.rules[index].categoryID = categoryID
        } else if entity.id.hasPrefix("app:") {
            let bundleID = String(entity.id.dropFirst("app:".count))
            if let index = next.rules.firstIndex(where: { $0.bundleIDs.contains(bundleID) }) {
                next.rules[index].categoryID = categoryID
            } else {
                next.rules.append(
                    AttentionIdentityRule(
                        name: entity.name, categoryID: categoryID, bundleIDs: [bundleID]))
            }
        } else if entity.id.hasPrefix("web:") {
            let domain = String(entity.id.dropFirst("web:".count))
            if let index = next.rules.firstIndex(where: { $0.domains.contains(domain) }) {
                next.rules[index].categoryID = categoryID
            } else {
                next.rules.append(
                    AttentionIdentityRule(
                        name: entity.name, categoryID: categoryID, domains: [domain]))
            }
        }
        settings = next
        saveSettings()
    }

    func addCategory() {
        settings.categories.append(
            AttentionCategory(
                id: "category-\(UUID().uuidString.lowercased())", name: "New category",
                kind: .neutral, color: "65789B"))
    }

    func removeCategory(at index: Int) {
        guard settings.categories.indices.contains(index), settings.categories.count > 1 else {
            return
        }
        let removed = settings.categories.remove(at: index)
        let fallback = settings.categories.first?.id ?? "unclassified"
        for ruleIndex in settings.rules.indices
        where settings.rules[ruleIndex].categoryID == removed.id {
            settings.rules[ruleIndex].categoryID = fallback
        }
    }

    func addRule() {
        settings.rules.append(
            AttentionIdentityRule(
                name: "New identity", categoryID: settings.categories.first?.id ?? "unclassified"))
    }

    func backupNow() {
        do {
            _ = try cloudBackup.backup()
            message = "Attention data backed up to iCloud Drive"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreBackup() {
        do {
            try cloudBackup.restoreWhenLocalStoreIsEmpty()
            message = "Attention backup restored"
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkBrowser() async {
        guard settings.isEnabled, settings.browserTrackingEnabled else {
            browserConnected = false
            return
        }
        browserConnected = await AttentionIngestionServer.isHealthy(port: settings.serverPort)
    }
}

private struct AttentionPageState: Sendable {
    var settings: AttentionSettings
    var summary: AttentionSummary
    var events: [AttentionEvent]
    var activeFocus: AttentionFocusSession?
    var focusSessions: [AttentionFocusSession]
    var hasStoredEvents: Bool
    var extensionInstalled: Bool
}
