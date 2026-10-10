import EdithExtensionSupport
import EdithHostCore
import ExtensionMarketplace
import Foundation
import Observation

@MainActor struct HostWorkflowEnvironment {
    let available: () -> [String: ExtensionPackage]
    let installed: () -> Set<String>
    let active: () -> Set<String>
    let refresh: () async throws -> Void
    let install: (String, ExtensionPackage?) async throws -> Void
    let restore: () async throws -> HostSettingsBackupResult
    let changed: () -> Void
}

@MainActor @Observable final class HostWorkflowOnboardingModel {
    enum Stage: Equatable { case workflows, review, installing, finished }
    enum InstallState: Equatable { case waiting, installing, ready, failed(String) }
    static let reviewPendingKey = HostSettingsCatalog.onboardingReviewPendingKey
    static let workflowKey = HostSettingsCatalog.workflowKey
    let entries: [HostExtension]
    private(set) var presented = false
    private(set) var stage = Stage.workflows
    private(set) var workflow = HostWorkflow.custom
    private(set) var icloudBackup = true
    private(set) var selected = Set<String>()
    private(set) var states: [String: InstallState] = [:]
    private(set) var failure: String?
    private(set) var busy = false
    private(set) var restoring = false
    private(set) var catalogRevision = 0
    private let defaults: UserDefaults
    private let environment: HostWorkflowEnvironment
    private var task: Task<Void, Never>?
    private var originalCompletion = false
    private var imported = false

    init(entries: [HostExtension], defaults: UserDefaults, environment: HostWorkflowEnvironment) {
        self.entries = entries
        self.defaults = defaults
        self.environment = environment
        icloudBackup = defaults.object(forKey: AppStorageKeys.Backup.icloud) as? Bool ?? true
    }

    var incomplete: Bool {
        !defaults.bool(forKey: HostSettingsCatalog.onboardingCompletedKey)
            || defaults.bool(forKey: Self.reviewPendingKey)
    }
    var cost: HostWorkflowCost {
        _ = catalogRevision
        return .calculate(
            selected: selected, available: environment.available(),
            installed: environment.installed())
    }
    var installedIDs: Set<String> { environment.installed() }
    var activeIDs: Set<String> { environment.active() }
    var canInstall: Bool { !busy && cost.complete && !selected.isEmpty }

    func present() {
        guard !busy else { return }
        originalCompletion = defaults.bool(forKey: HostSettingsCatalog.onboardingCompletedKey)
        imported = false
        presented = true
        stage = .workflows
        states = [:]
        failure = nil
        let saved = defaults.stringArray(forKey: HostSettingsCatalog.workflowSelectionKey) ?? []
        if defaults.bool(forKey: Self.reviewPendingKey), saved.count <= entries.count {
            selected = Set(saved).intersection(Set(entries.map(\.id)))
            workflow =
                HostWorkflow(rawValue: defaults.string(forKey: Self.workflowKey) ?? "") ?? .custom
            if !selected.isEmpty { stage = .review }
        } else {
            selected = []
        }
        defaults.set(true, forKey: Self.reviewPendingKey)
        environment.changed()
    }

    func choose(_ workflow: HostWorkflow) {
        guard !busy else { return }
        self.workflow = workflow
        selected = workflow.suggestions.intersection(Set(entries.map(\.id)))
        stage = .review
        saveSelection()
        states = [:]
        failure = nil
    }

    func toggle(_ id: String) {
        guard !busy, entries.contains(where: { $0.id == id }) else { return }
        if !selected.insert(id).inserted { selected.remove(id) }
        states = [:]
        saveSelection()
    }

    func setICloudBackup(_ enabled: Bool) { guard !busy else { return }; icloudBackup = enabled }

    func back() { guard !busy else { return }; stage = .workflows }

    func refreshCatalog() {
        guard !busy else { return }
        run { model in
            try await model.environment.refresh()
            try Task.checkCancellation()
            model.catalogRevision += 1
        }
    }

    func restoreSelection() {
        guard !busy else { return }
        defaults.set(true, forKey: Self.reviewPendingKey)
        restoring = true
        run { model in
            defer { model.restoring = false }
            let result = try await model.environment.restore()
            model.imported = true
            model.defaults.set(false, forKey: HostSettingsCatalog.onboardingCompletedKey)
            model.icloudBackup =
                model.defaults.object(forKey: AppStorageKeys.Backup.icloud) as? Bool ?? true
            try Task.checkCancellation()
            model.selected = Set(result.suggestedExtensionIDs).intersection(
                Set(model.entries.map(\.id)))
            model.workflow = .custom
            model.stage = .review
            model.saveSelection()
            model.environment.changed()
        }
    }

    func installSelection() {
        guard canInstall else { return }
        let chosen = selected.sorted()
        defaults.set(icloudBackup, forKey: AppStorageKeys.Backup.icloud)
        environment.changed()
        states = Dictionary(uniqueKeysWithValues: chosen.map { ($0, .waiting) })
        stage = .installing
        run { model in
            let reviewed = model.environment.available()
            try await model.environment.refresh()
            try Task.checkCancellation()
            model.catalogRevision += 1
            let current = model.environment.available()
            let required = HostWorkflowCost.calculate(
                selected: Set(chosen), available: reviewed, installed: model.environment.installed()
            ).packageIDs
            guard required.allSatisfy({ reviewed[$0] == current[$0] }) else {
                model.stage = .review
                throw HostWorkflowFailure(
                    "Extension versions or sizes changed. Review your selection and try again.")
            }
            for id in chosen {
                try Task.checkCancellation()
                if model.environment.installed().contains(id),
                    model.environment.active().contains(id)
                {
                    model.states[id] = .ready
                    continue
                }
                model.states[id] = .installing
                do {
                    try await model.environment.install(id, reviewed[id])
                    try Task.checkCancellation()
                    guard model.environment.installed().contains(id),
                        model.environment.active().contains(id)
                    else {
                        throw HostWorkflowFailure(
                            "The downloaded extension could not start. Retry to finish setup.")
                    }
                    model.states[id] = .ready
                } catch is CancellationError { throw CancellationError() } catch let error
                    as HostWorkflowReviewChanged
                {
                    model.stage = .review
                    throw error
                } catch {
                    model.states[id] = .failed(error.localizedDescription)
                }
            }
            guard
                chosen.allSatisfy({
                    model.states[$0] == .ready && model.environment.active().contains($0)
                })
            else {
                throw HostWorkflowFailure(
                    "Some extensions could not finish. Your working extensions remain available. Retry the failed extensions."
                )
            }
            model.complete()
        }
    }

    var skipTitle: String {
        environment.active().isEmpty ? "Start without extensions" : "Keep current setup"
    }

    func skip() {
        guard !busy else { return }
        selected = []
        complete()
    }

    func dismiss() {
        guard !busy else { return }
        if imported && stage != .finished { return }
        defaults.set(
            stage == .finished || originalCompletion,
            forKey: HostSettingsCatalog.onboardingCompletedKey)
        defaults.set(false, forKey: Self.reviewPendingKey)
        presented = false
        environment.changed()
    }

    func openStorage() {
        guard stage == .finished, !busy else { return }
        dismiss()
        defaults.set("storage", forKey: AppStorageKeys.General.settingsTab)
        defaults.set("settings", forKey: AppStorageKeys.General.mainWindowSection)
    }

    func cancel() { task?.cancel() }
    func shutdown() async {
        let owned = task
        owned?.cancel()
        await owned?.value
        task = nil
    }

    private func complete() {
        defaults.set(icloudBackup, forKey: AppStorageKeys.Backup.icloud)
        saveSelection()
        let categories = Set(entries.filter { selected.contains($0.id) }.map(\.category))
        for suite in HostMarketplaceCatalog.suites where categories.contains(suite.id) {
            defaults.set(true, forKey: suite.defaultsKey)
        }
        defaults.set(true, forKey: HostSettingsCatalog.onboardingCompletedKey)
        defaults.set(false, forKey: Self.reviewPendingKey)
        defaults.synchronize()
        stage = .finished
        environment.changed()
    }

    private func saveSelection() {
        defaults.set(workflow.rawValue, forKey: Self.workflowKey)
        defaults.set(selected.sorted(), forKey: HostSettingsCatalog.workflowSelectionKey)
        defaults.synchronize()
    }

    private func run(
        _ action: @escaping @MainActor (HostWorkflowOnboardingModel) async throws -> Void
    ) {
        guard !busy else { return }
        busy = true
        failure = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; task = nil }
            do { try await action(self) } catch is CancellationError {
                if stage == .installing {
                    failure = "Setup was cancelled. Downloaded extensions remain installed."
                }
            } catch { failure = error.localizedDescription }
        }
    }
}

struct HostWorkflowFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct HostWorkflowReviewChanged: LocalizedError {
    var errorDescription: String? {
        "The extension package changed. Review your selection and try again."
    }
}
