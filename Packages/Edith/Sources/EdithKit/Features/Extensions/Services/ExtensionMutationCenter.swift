import EdithCore
import Foundation

public enum ExtensionMutationOperation: String, CaseIterable, Sendable {
    case enable
    case disable
    case setup
    case provisionTool

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .enable:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "extensions.enable"),
                summary: "Enable an Edith extension.", cli: ["extensions", "enable"],
                effect: .write)
        case .disable:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "extensions.disable"),
                summary: "Disable an Edith extension.", cli: ["extensions", "disable"],
                effect: .write)
        case .setup:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "extensions.setup"),
                summary: "Enable an extension and provision its required tools.",
                cli: ["extensions", "setup"], effect: .write)
        case .provisionTool:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "extensions.provision-tool"),
                summary: "Install a command-line tool required by an extension.",
                cli: ["tools", "install"], effect: .write)
        }
    }
}

public struct ExtensionPermissionPlan: Equatable, Sendable {
    public let entry: ExtensionRegistryEntry
    public let required: [ExtensionPermission]
    public let optional: [ExtensionPermission]

    public init(
        entry: ExtensionRegistryEntry, required: [ExtensionPermission],
        optional: [ExtensionPermission]
    ) {
        self.entry = entry
        self.required = required
        self.optional = optional
    }
}

public struct ExtensionMutationResult: Equatable, Sendable {
    public let entry: ExtensionRegistryEntry
    public let enabled: Bool
    public let changed: Bool
    public let missingRequiredPermissions: [ExtensionPermission]

    public init(
        entry: ExtensionRegistryEntry, enabled: Bool, changed: Bool,
        missingRequiredPermissions: [ExtensionPermission]
    ) {
        self.entry = entry
        self.enabled = enabled
        self.changed = changed
        self.missingRequiredPermissions = missingRequiredPermissions
    }
}

public enum ExtensionEnableOutcome: Equatable, Sendable {
    case applied(ExtensionMutationResult)
    case needsPermissions(ExtensionPermissionPlan)
}

public struct ExtensionToolFailure: Equatable, Sendable {
    public let id: String
    public let detail: String

    public init(id: String, detail: String) {
        self.id = id
        self.detail = detail
    }
}

public struct ExtensionToolProvisionResult: Equatable, Sendable {
    public let planned: [String]
    public let installed: [String]
    public let failures: [ExtensionToolFailure]

    public init(
        planned: [String], installed: [String], failures: [ExtensionToolFailure]
    ) {
        self.planned = planned
        self.installed = installed
        self.failures = failures
    }
}

public struct ExtensionSetupResult: Equatable, Sendable {
    public let entry: ExtensionRegistryEntry
    public let dryRun: Bool
    public let changed: Bool
    public let tools: ExtensionToolProvisionResult
    public let report: ExtensionLifecycleReport

    public init(
        entry: ExtensionRegistryEntry, dryRun: Bool, changed: Bool,
        tools: ExtensionToolProvisionResult, report: ExtensionLifecycleReport
    ) {
        self.entry = entry
        self.dryRun = dryRun
        self.changed = changed
        self.tools = tools
        self.report = report
    }
}

public struct ExtensionOnboardingResult: Equatable, Sendable {
    public let enabledIDs: [String]
    public let iCloudBackup: Bool

    public init(enabledIDs: [String], iCloudBackup: Bool) {
        self.enabledIDs = enabledIDs
        self.iCloudBackup = iCloudBackup
    }
}

public struct ExtensionMutationEnvironment: @unchecked Sendable {
    public typealias InstallTool =
        @Sendable (CLIToolSpec, @escaping @Sendable (String) -> Void) async throws -> String

    public let defaults: UserDefaults
    public var announceChange: @Sendable () -> Void
    public var grantedPermissions: @Sendable () -> [ExtensionPermission: Bool]
    public var toolAvailable: @Sendable (String) -> Bool
    public var installTool: InstallTool
    public var lifecycle: ExtensionLifecycleProbeEnvironment

    public init(
        defaults: UserDefaults, announceChange: @escaping @Sendable () -> Void,
        grantedPermissions: @escaping @Sendable () -> [ExtensionPermission: Bool],
        toolAvailable: @escaping @Sendable (String) -> Bool,
        installTool: @escaping InstallTool,
        lifecycle: ExtensionLifecycleProbeEnvironment
    ) {
        self.defaults = defaults
        self.announceChange = announceChange
        self.grantedPermissions = grantedPermissions
        self.toolAvailable = toolAvailable
        self.installTool = installTool
        self.lifecycle = lifecycle
    }

    public static let live = ExtensionMutationEnvironment(
        defaults: SharedDefaults.store,
        announceChange: { IPC.post(IPC.Name.settingsChanged) },
        grantedPermissions: { PermissionsStatus.granted },
        toolAvailable: { id in
            guard let tool = ToolProvisioning.spec(id: id),
                case let .executable(name, _) = tool.presenceStrategy
            else { return false }
            return CLIToolEnvironment.executable(named: name) != nil
        },
        installTool: { tool, log in try await ToolInstaller().install(tool, log: log) },
        lifecycle: .live)
}

public struct ExtensionMutationCenter: Sendable {
    public let environment: ExtensionMutationEnvironment

    public init(environment: ExtensionMutationEnvironment = .live) {
        self.environment = environment
    }

    public func isEnabled(_ entry: ExtensionRegistryEntry) -> Bool {
        environment.defaults.object(forKey: entry.defaultsKey) as? Bool ?? false
    }

    public func setEnabled(
        _ enabled: Bool, for entry: ExtensionRegistryEntry, markPermissionsSeen: Bool = false,
        announce: Bool = true
    ) -> ExtensionMutationResult {
        let wasEnabled = isEnabled(entry)
        environment.defaults.set(enabled, forKey: entry.defaultsKey)
        reconcileDependencies(for: entry, enabled: enabled)
        if markPermissionsSeen {
            environment.defaults.set(true, forKey: OnboardingFlow.seenKey(for: entry))
        }
        environment.defaults.synchronize()
        if announce { environment.announceChange() }
        let granted = environment.grantedPermissions()
        return ExtensionMutationResult(
            entry: entry, enabled: enabled, changed: wasEnabled != enabled,
            missingRequiredPermissions: entry.requiredPermissions.filter {
                granted[$0] != true
            })
    }

    public func enablePermissionAware(_ entry: ExtensionRegistryEntry) -> ExtensionEnableOutcome {
        let granted = environment.grantedPermissions()
        let seen = environment.defaults.bool(forKey: OnboardingFlow.seenKey(for: entry))
        switch ExtensionPermissionFlow.decision(
            for: entry, granted: granted, hasSeenPermissions: seen)
        {
        case .enableDirectly:
            return .applied(
                setEnabled(true, for: entry, markPermissionsSeen: true))
        case let .showSheet(required, optional):
            return .needsPermissions(
                ExtensionPermissionPlan(
                    entry: entry, required: required, optional: optional))
        }
    }

    public func completeOnboarding(
        selectedIDs: Set<String>, icloudBackup: Bool = OnboardingFlow.initialICloudBackup,
        entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries
    ) -> ExtensionOnboardingResult {
        let selected = entries.filter { selectedIDs.contains($0.id) }
        for entry in selected {
            _ = setEnabled(
                true, for: entry, markPermissionsSeen: true, announce: false)
        }
        environment.defaults.set(icloudBackup, forKey: OnboardingFlow.iCloudBackupKey)
        environment.defaults.set(true, forKey: OnboardingFlow.completionKey)
        environment.defaults.synchronize()
        return ExtensionOnboardingResult(
            enabledIDs: selected.map(\.id), iCloudBackup: icloudBackup)
    }

    public func missingTools(for entry: ExtensionRegistryEntry) -> [CLIToolSpec] {
        entry.requiredTools.filter { !environment.toolAvailable($0.id) }
    }

    public func provision(
        _ tools: [CLIToolSpec], log: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> ExtensionToolProvisionResult {
        var installed: [String] = []
        var failures: [ExtensionToolFailure] = []
        for tool in tools {
            do {
                _ = try await environment.installTool(tool, log)
                installed.append(tool.id)
            } catch {
                failures.append(
                    ExtensionToolFailure(id: tool.id, detail: error.localizedDescription))
            }
        }
        return ExtensionToolProvisionResult(
            planned: tools.map(\.id), installed: installed, failures: failures)
    }

    public func setup(
        _ entry: ExtensionRegistryEntry, dryRun: Bool, installTools: Bool,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> ExtensionSetupResult {
        let wasEnabled = isEnabled(entry)
        var lifecycle = environment.lifecycle
        let missing = entry.requiredTools.filter { !environment.toolAvailable($0.id) }
        let provisioning: ExtensionToolProvisionResult
        if dryRun {
            let original = lifecycle.isEnabled
            lifecycle.isEnabled = { candidate in
                candidate.id == entry.id ? true : original(candidate)
            }
            provisioning = ExtensionToolProvisionResult(
                planned: installTools ? missing.map(\.id) : [], installed: [], failures: [])
        } else {
            _ = setEnabled(true, for: entry)
            provisioning =
                installTools
                ? await provision(missing, log: log)
                : ExtensionToolProvisionResult(planned: [], installed: [], failures: [])
        }
        let report = await ExtensionLifecycleProbe(environment: lifecycle).report(for: entry)
        return ExtensionSetupResult(
            entry: entry, dryRun: dryRun, changed: !dryRun && !wasEnabled,
            tools: provisioning, report: report)
    }

    private func reconcileDependencies(for entry: ExtensionRegistryEntry, enabled: Bool) {
        if entry.id == "usage", enabled,
            !environment.defaults.bool(forKey: AppStorageKeys.Limits.claudeEnabled),
            !environment.defaults.bool(forKey: AppStorageKeys.Limits.codexEnabled)
        {
            let selected =
                LimitProvider(
                    rawValue: environment.defaults.string(
                        forKey: AppStorageKeys.Limits.provider) ?? "") ?? .claude
            environment.defaults.set(
                true,
                forKey: selected == .claude
                    ? AppStorageKeys.Limits.claudeEnabled : AppStorageKeys.Limits.codexEnabled)
        }
        if entry.id == "system", !enabled {
            environment.defaults.set(false, forKey: AppStorageKeys.General.preventSleep)
        }
    }
}
