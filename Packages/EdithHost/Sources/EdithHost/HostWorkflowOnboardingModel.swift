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

extension HostWorkflowEnvironment {
    static let resumeStageKey = "onboardingResumeStage"
}

struct HostWorkflowPackageReview: Equatable {
    let version: String?
    let downloadBytes: Int64?
    let installedBytes: Int64?

    init(package: ExtensionPackage?) {
        let version = package?.version.trimmingCharacters(in: .whitespacesAndNewlines)
        self.version = version?.isEmpty == false ? version : nil
        downloadBytes = package.flatMap { $0.downloadBytes > 0 ? $0.downloadBytes : nil }
        installedBytes = package.flatMap { $0.installedBytes > 0 ? $0.installedBytes : nil }
    }

    var summary: String {
        let version = version.map { "Catalog version \($0)" } ?? "Catalog version unavailable"
        let download =
            downloadBytes.map {
                "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) download"
            } ?? "Download size unknown"
        let installed =
            installedBytes.map {
                "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) unpacked"
            } ?? "Unpacked size unknown"
        return [version, download, installed].joined(separator: " · ")
    }
}

@MainActor @Observable final class HostWorkflowOnboardingModel {
    enum Stage: String, Equatable, CaseIterable {
        case welcome, workflows, tools, permissions, installing, finished

        var position: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        var resumable: Bool { [.welcome, .workflows, .tools, .permissions].contains(self) }
    }
    enum InstallState: Equatable { case waiting, installing, ready, failed(String) }
    static let reviewPendingKey = HostSettingsCatalog.onboardingReviewPendingKey
    static let workflowKey = HostSettingsCatalog.workflowKey
    let entries: [HostExtension]
    private(set) var presented = false
    private(set) var stage = Stage.welcome {
        didSet {
            advancing = stage.position >= oldValue.position
            persistStage()
        }
    }
    private(set) var advancing = true
    private(set) var workflow = HostWorkflow.custom
    private(set) var icloudBackup = true
    private(set) var selected = Set<String>()
    private(set) var states: [String: InstallState] = [:]
    private(set) var failure: String?
    private(set) var busy = false
    private(set) var restoring = false
    private(set) var catalogRevision = 0
    private(set) var deferredPermissions = Set<HostPermission>()
    let permissions: HostPermissions
    private let defaults: UserDefaults
    private let environment: HostWorkflowEnvironment
    private var task: Task<Void, Never>?
    private var originalCompletion = false
    private var imported = false

    init(
        entries: [HostExtension], defaults: UserDefaults, environment: HostWorkflowEnvironment,
        permissions: HostPermissions = HostPermissions()
    ) {
        self.entries = entries
        self.permissions = permissions
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
    var offeredIDs: Set<String> {
        _ = catalogRevision
        return Set(environment.available().keys).union(installedIDs)
    }
    var visibleEntries: [HostExtension] {
        let visible = offeredIDs.union(selected)
        return entries.filter { visible.contains($0.id) }
    }
    func reviewMetadata(for id: String) -> HostWorkflowPackageReview {
        _ = catalogRevision
        return HostWorkflowPackageReview(package: environment.available()[id])
    }

    var selectedEntries: [HostExtension] { entries.filter { selected.contains($0.id) } }
    var permissionItems: [HostOnboardingPermission] {
        HostOnboardingPermissionPlan.items(
            selected: selectedEntries, granted: permissions.granted)
    }
    var currentPermission: HostPermission? {
        HostOnboardingPermissionPlan.current(permissionItems, deferred: deferredPermissions)
    }
    var relaunchBatch: [HostPermission] {
        HostOnboardingPermissionPlan.relaunchBatch(
            permissionItems, awaiting: permissions.awaitingRelaunch)
    }
    var groups: [(category: String, entries: [HostExtension])] {
        let visible = visibleEntries
        let categories = Dictionary(grouping: visible, by: \.category)
        let order = [workflow.rawValue] + HostWorkflow.allCases.map(\.rawValue)
        let known = order.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let ranked = known + categories.keys.filter { !known.contains($0) }.sorted()
        return ranked.compactMap { category in
            categories[category].map { (category, $0) }
        }
    }
    func tagline(for entry: HostExtension) -> String {
        HostMarketplaceCatalog.tagline(entry)
    }

    var canInstall: Bool { !busy && cost.complete && !selected.isEmpty }

    func present() {
        guard !busy else { return }
        originalCompletion = defaults.bool(forKey: HostSettingsCatalog.onboardingCompletedKey)
        imported = false
        let resumeStage = defaults.string(forKey: HostWorkflowEnvironment.resumeStageKey)
            .flatMap(Stage.init(rawValue:))
        presented = true
        stage = .welcome
        states = [:]
        failure = nil
        deferredPermissions = []
        let saved = defaults.stringArray(forKey: HostSettingsCatalog.workflowSelectionKey) ?? []
        if defaults.bool(forKey: Self.reviewPendingKey), saved.count <= entries.count {
            selected = Set(saved).intersection(Set(entries.map(\.id)))
            workflow =
                HostWorkflow(rawValue: defaults.string(forKey: Self.workflowKey) ?? "") ?? .custom
            stage = Self.resumed(resumeStage, hasSelection: !selected.isEmpty)
        } else {
            selected = []
        }
        defaults.set(true, forKey: Self.reviewPendingKey)
        environment.changed()
    }

    static func resumed(_ saved: Stage?, hasSelection: Bool) -> Stage {
        guard let saved, saved.resumable else { return hasSelection ? .tools : .welcome }
        if !hasSelection, [.tools, .permissions].contains(saved) { return .workflows }
        return saved
    }

    func choose(_ workflow: HostWorkflow) {
        guard !busy else { return }
        self.workflow = workflow
        selected = workflow.suggestions(in: entries).intersection(
            offeredIDs)
        stage = .tools
        saveSelection()
        states = [:]
        failure = nil
    }

    func toggle(_ id: String) {
        guard !busy, entries.contains(where: { $0.id == id }) else { return }
        guard selected.contains(id) || offeredIDs.contains(id) else { return }
        if !selected.insert(id).inserted { selected.remove(id) }
        states = [:]
        saveSelection()
    }

    func setICloudBackup(_ enabled: Bool) { guard !busy else { return }; icloudBackup = enabled }

    func setGroup(_ category: String, selected enabled: Bool) {
        guard !busy else { return }
        let ids = entries.filter { $0.category == category && offeredIDs.contains($0.id) }
            .map(\.id)
        if enabled { selected.formUnion(ids) } else { selected.subtract(ids) }
        states = [:]
        saveSelection()
    }

    func groupSelected(_ category: String) -> Bool {
        let ids = entries.filter { $0.category == category && offeredIDs.contains($0.id) }
        return !ids.isEmpty && ids.allSatisfy { selected.contains($0.id) }
    }

    func start() { guard !busy, stage == .welcome else { return }; stage = .workflows }

    func back() {
        guard !busy else { return }
        switch stage {
        case .welcome, .finished: break
        case .workflows: stage = .welcome
        case .tools: stage = .workflows
        case .permissions: stage = .tools
        case .installing: stage = permissionItems.isEmpty ? .tools : .permissions
        }
    }

    func continueFromTools() {
        guard stage == .tools, canInstall else { return }
        refreshPermissions()
        if permissionItems.isEmpty { installSelection() } else { stage = .permissions }
    }

    func skipStep() {
        guard !busy else { return }
        switch stage {
        case .welcome: stage = .workflows
        case .workflows:
            workflow = .custom
            stage = .tools
        case .tools: skip()
        case .permissions: installSelection()
        case .installing, .finished: break
        }
    }

    func refreshPermissions() { Task { await permissions.refresh() } }

    func watchPermissions(interval: Duration = .seconds(1)) async {
        await permissions.watch(
            interval: interval,
            while: { [weak self] in
                self?.stage == .permissions
            })
    }

    func requestPermission(_ permission: HostPermission) async {
        guard stage == .permissions, !busy else { return }
        deferredPermissions.remove(permission)
        await permissions.request(permission)
    }

    func openSettings(_ permission: HostPermission) {
        guard stage == .permissions else { return }
        _ = permissions.openSettings(permission)
    }

    func deferPermission(_ permission: HostPermission, _ deferred: Bool) {
        guard stage == .permissions,
            permissionItems.first(where: { $0.permission == permission })?.canDefer == true
        else { return }
        if deferred {
            deferredPermissions.insert(permission)
        } else {
            deferredPermissions.remove(permission)
        }
    }

    func relaunch() {
        guard stage == .permissions, !busy, !relaunchBatch.isEmpty else { return }
        defaults.set(true, forKey: Self.reviewPendingKey)
        persistStage()
        saveSelection()
        permissions.relaunch()
    }

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
            model.stage = .tools
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
                model.stage = .tools
                throw HostWorkflowFailure(
                    "Some tools changed since you picked them. Review your selection and try again."
                )
            }
            var installs: [Task<Void, Error>] = []
            for id in chosen {
                if model.environment.installed().contains(id),
                    model.environment.active().contains(id)
                {
                    model.states[id] = .ready
                    continue
                }
                model.states[id] = .installing
                installs.append(
                    Task {
                        do {
                            try await model.environment.install(id, reviewed[id])
                            try Task.checkCancellation()
                            guard model.environment.installed().contains(id),
                                model.environment.active().contains(id)
                            else {
                                throw HostWorkflowFailure(
                                    "The tool downloaded but could not start. Retry to finish setup."
                                )
                            }
                            model.states[id] = .ready
                        } catch is CancellationError { throw CancellationError() } catch let error
                            as HostWorkflowReviewChanged
                        {
                            model.stage = .tools
                            throw error
                        } catch {
                            model.states[id] = .failed(error.localizedDescription)
                        }
                    })
            }
            let started = installs
            try await withTaskCancellationHandler {
                for install in started { try await install.value }
            } onCancel: {
                for install in started { install.cancel() }
            }
            guard
                chosen.allSatisfy({
                    model.states[$0] == .ready && model.environment.active().contains($0)
                })
            else {
                throw HostWorkflowFailure(
                    "Some tools could not finish. The ones that did are ready to use."
                )
            }
            model.complete()
        }
    }

    var skipTitle: String {
        environment.active().isEmpty ? "Start without tools" : "Keep current setup"
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
        defaults.removeObject(forKey: HostWorkflowEnvironment.resumeStageKey)
        environment.changed()
    }

    func openStorage() { openSettings("storage") }

    func openAgents() { openSettings("mcp") }

    private func openSettings(_ tab: String) {
        guard stage == .finished, !busy else { return }
        dismiss()
        defaults.set(tab, forKey: AppStorageKeys.General.settingsTab)
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

    func open(page: String) {
        guard stage == .finished, !busy else { return }
        dismiss()
        defaults.set(page, forKey: AppStorageKeys.General.mainWindowSection)
    }

    func destination(for entry: HostExtension) -> HostNavigationPage? {
        guard entry.page != nil else { return nil }
        return HostNavigationCatalog.pages(entries).first { $0.extensionID == entry.id }
    }

    private func persistStage() {
        if stage.resumable {
            defaults.set(stage.rawValue, forKey: HostWorkflowEnvironment.resumeStageKey)
        } else {
            defaults.removeObject(forKey: HostWorkflowEnvironment.resumeStageKey)
        }
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
                    failure = "Setup was cancelled. Tools that finished stay installed."
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
