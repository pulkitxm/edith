import AppKit
import EdithCore
import Foundation

public enum ExtensionAdapterReadiness: Equatable, Sendable {
    case ready(String)
    case degraded(String)
    case needsSetup(String)
    case uninstalled(String)
    case empty(String)
    case loading(String)
    case unsupported(String)
    case failed(String)
}

public enum ExtensionToolReadiness: Equatable, Sendable {
    case installed(version: String)
    case uninstalled
    case error(String)
}

public struct ExtensionLifecycleProbeEnvironment: Sendable {
    public var isEnabled: @Sendable (ExtensionRegistryEntry) -> Bool
    public var grantedPermissions: @Sendable () -> [ExtensionPermission: Bool]
    public var toolReadiness: @Sendable (String) async -> ExtensionToolReadiness
    public var helperRunning: @Sendable () -> Bool
    public var platformCapabilities: PlatformCapabilities
    public var usesOptionalCapability: @Sendable (PlatformCapability) -> Bool
    public var machineCount: @Sendable () -> Int
    public var adapterReadiness: @Sendable (String) async -> ExtensionAdapterReadiness?
    public var companionEndpoint: @Sendable () -> URL
    public var companionConfigured: @Sendable () -> Bool

    public init(
        isEnabled: @escaping @Sendable (ExtensionRegistryEntry) -> Bool,
        grantedPermissions: @escaping @Sendable () -> [ExtensionPermission: Bool],
        toolReadiness: @escaping @Sendable (String) async -> ExtensionToolReadiness,
        helperRunning: @escaping @Sendable () -> Bool,
        platformCapabilities: PlatformCapabilities,
        usesOptionalCapability: @escaping @Sendable (PlatformCapability) -> Bool = { _ in true },
        machineCount: @escaping @Sendable () -> Int,
        adapterReadiness: @escaping @Sendable (String) async -> ExtensionAdapterReadiness?,
        companionEndpoint: @escaping @Sendable () -> URL = {
            CompanionClient.endpoint(override: nil)
        },
        companionConfigured: @escaping @Sendable () -> Bool = {
            CompanionClient.hasConfiguredEndpointOrDeployment()
        }
    ) {
        self.isEnabled = isEnabled
        self.grantedPermissions = grantedPermissions
        self.toolReadiness = toolReadiness
        self.helperRunning = helperRunning
        self.platformCapabilities = platformCapabilities
        self.usesOptionalCapability = usesOptionalCapability
        self.machineCount = machineCount
        self.adapterReadiness = adapterReadiness
        self.companionEndpoint = companionEndpoint
        self.companionConfigured = companionConfigured
    }

    public static let live = ExtensionLifecycleProbeEnvironment(
        isEnabled: { entry in
            entry.isEnabled(in: SharedDefaults.store)
        },
        grantedPermissions: { PermissionOperationCenter.application.grantedPermissions() },
        toolReadiness: { await toolReadiness($0) },
        helperRunning: {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: MainApp.statusBarBundleIdentifier
            ).isEmpty
        },
        platformCapabilities: .macOS,
        usesOptionalCapability: { capability in
            switch capability {
            case .applicationAudio:
                SharedDefaults.store.bool(forKey: AppStorageKeys.Notch.audioMixerEnabled)
            default:
                true
            }
        },
        machineCount: { MachineRegistry.machines().count },
        adapterReadiness: { id in
            switch id {
            case "companion": nil
            case "herdr": await herdrReadiness()
            default: await ExtensionLiveAdapters.readiness(for: id)
            }
        })

    public static func toolReadiness(
        _ id: String,
        executableNamed: @escaping @Sendable (String) -> URL? = {
            CLIToolEnvironment.executable(named: $0)
        },
        detectedVersion: @escaping @Sendable (CLIToolSpec) async -> String? = {
            await ToolInstaller().detectedVersion(of: $0)
        }
    ) async -> ExtensionToolReadiness {
        guard let tool = ToolProvisioning.spec(id: id),
            case let .executable(name, _) = tool.presenceStrategy
        else { return .error("No tool specification is registered for \(id).") }
        guard let executable = executableNamed(name) else { return .uninstalled }
        guard let version = await detectedVersion(tool) else {
            return .error(
                "Found \(tool.displayName) at \(executable.path), but its version probe failed.")
        }
        return .installed(version: version)
    }

    static func companionReadiness(
        baseURL: URL, configured: Bool
    ) async -> ExtensionAdapterReadiness {
        do {
            let health = try await CompanionClient(baseURL: baseURL).health()
            return companionReadiness(health)
        } catch {
            return companionFailureReadiness(
                error.localizedDescription, configured: configured)
        }
    }

    private static func herdrReadiness() async -> ExtensionAdapterReadiness {
        let hosts = await HerdrCollector.collect()
        return herdrReadiness(hosts)
    }

    static func companionReadiness(_ health: CompanionHealth) -> ExtensionAdapterReadiness {
        if !health.blocking.isEmpty {
            return .failed(
                health.blocking.map { "\($0.name): \($0.detail)" }.joined(separator: "; "))
        }
        if !health.failing.isEmpty {
            return .degraded(
                health.failing.map { "\($0.name): \($0.detail)" }.joined(separator: "; "))
        }
        return .ready("Companion backend and dependencies are healthy.")
    }

    static func companionFailureReadiness(
        _ detail: String, configured: Bool
    ) -> ExtensionAdapterReadiness {
        guard configured else {
            return .uninstalled(
                "Companion is not configured. Choose a host and deploy it, or save another endpoint."
            )
        }
        return .failed("Companion backend is unreachable: \(detail)")
    }

    static func herdrReadiness(_ hosts: [HerdrHostSnapshot]) -> ExtensionAdapterReadiness {
        let installed = hosts.filter(\.herdrPresent)
        guard !installed.isEmpty else {
            return .uninstalled("Herdr is not installed on this Mac or a configured machine.")
        }
        let agents = installed.flatMap(\.agents)
        guard !agents.isEmpty else {
            return .empty("Herdr is installed, but no live sessions were found.")
        }
        let errors = hosts.compactMap(\.error)
        if !errors.isEmpty {
            return .degraded(
                "Found \(agents.count) live sessions; some hosts failed: "
                    + errors.joined(separator: "; "))
        }
        return .ready("Found \(agents.count) live Herdr sessions.")
    }
}

public struct ExtensionLifecycleProbe: Sendable {
    enum ToolRule: Equatable, Sendable {
        case all
        case any
    }

    struct Policy: Equatable, Sendable {
        let requiresHelper: Bool
        let requiresMachine: Bool
        let toolRule: ToolRule
        let adapter: Bool
    }

    static let policies: [String: Policy] = [
        "attention": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
        "usage": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .any, adapter: true),
        "herdr": Policy(
            requiresHelper: false, requiresMachine: false, toolRule: .all, adapter: true),
        "quinjet": Policy(
            requiresHelper: false, requiresMachine: false, toolRule: .all, adapter: true),
        "system": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
        "machines": Policy(
            requiresHelper: true, requiresMachine: true, toolRule: .all, adapter: true),
        "companion": Policy(
            requiresHelper: false, requiresMachine: false, toolRule: .all, adapter: true),
        "systemStats": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
        "micMute": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
        "lidAwake": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
        "music": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
        "calendar": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
        "notchShelf": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
        "clipboard": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
        "focusDim": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
        "presenter": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
        "colorPicker": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
        "emoji": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: true),
    ]

    public let environment: ExtensionLifecycleProbeEnvironment

    public init(environment: ExtensionLifecycleProbeEnvironment = .live) {
        self.environment = environment
    }

    public func report(for entry: ExtensionRegistryEntry) async -> ExtensionLifecycleReport {
        let enabled = environment.isEnabled(entry)
        guard let policy = Self.policies[entry.id] else {
            return ExtensionLifecycleReport(
                state: ExtensionLifecycleState(
                    extensionID: entry.id, phase: .failed, runtimePhase: .error,
                    summary: "No lifecycle adapter is registered.",
                    issues: [
                        ExtensionLifecycleIssue(
                            id: "adapter", title: "Missing lifecycle adapter",
                            detail: "The extension registry and lifecycle probe are out of sync.")
                    ]),
                checks: [])
        }

        var checks = [
            check(
                "enabled", "Extension enabled", enabled ? .passed : .skipped,
                enabled
                    ? "Enabled in shared settings."
                    : "Disabled in shared settings; runtime checks still run.",
                enabled ? nil : "ed extensions setup \(entry.id)")
        ]
        checks.append(platformCheck(entry))
        checks.append(contentsOf: permissionChecks(entry))
        checks.append(contentsOf: await toolChecks(entry, rule: policy.toolRule))
        checks.append(contentsOf: await optionalToolChecks(entry))
        if policy.requiresHelper { checks.append(helperCheck()) }
        if policy.requiresMachine { checks.append(machineCheck()) }
        if policy.adapter {
            let readiness = await adapterReadiness(entry.id)
            checks.append(adapterCheck(entry, readiness: readiness))
        }
        return report(entry, enabled: enabled, checks: checks)
    }

    private func adapterReadiness(_ id: String) async -> ExtensionAdapterReadiness {
        if let readiness = await environment.adapterReadiness(id) { return readiness }
        guard id == "companion" else {
            return .failed("No live runtime adapter is registered for \(id).")
        }
        return await ExtensionLifecycleProbeEnvironment.companionReadiness(
            baseURL: environment.companionEndpoint(),
            configured: environment.companionConfigured())
    }

    public func reports(
        for entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries
    ) async -> [ExtensionLifecycleReport] {
        await withTaskGroup(of: (Int, ExtensionLifecycleReport).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask { (index, await report(for: entry)) }
            }
            var reports: [(Int, ExtensionLifecycleReport)] = []
            for await report in group { reports.append(report) }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func platformCheck(_ entry: ExtensionRegistryEntry) -> ExtensionLifecycleCheck {
        let optionalCapabilities = entry.optionalCapabilities.filter(
            environment.usesOptionalCapability)
        switch environment.platformCapabilities.availability(
            required: entry.requiredCapabilities, optional: optionalCapabilities)
        {
        case .available:
            return check(
                "platform", "Platform support", .passed, "Required capabilities are available.")
        case let .degraded(capabilities):
            return check(
                "platform", "Platform support", .warning,
                "Optional capabilities are unavailable: \(names(capabilities)).")
        case let .unavailable(capabilities):
            return check(
                "platform", "Platform support", .failed,
                "Required capabilities are unavailable: \(names(capabilities)).", nil,
                runtimePhase: .unsupported)
        }
    }

    private func permissionChecks(_ entry: ExtensionRegistryEntry) -> [ExtensionLifecycleCheck] {
        let granted = environment.grantedPermissions()
        let required = entry.requiredPermissions.map { permission in
            permissionCheck(permission, required: true, granted: granted[permission] == true)
        }
        let optional: [ExtensionLifecycleCheck] = entry.optionalPermissions.compactMap {
            permission in
            guard permission.grantedDefaultsKey != nil else { return nil }
            return permissionCheck(
                permission, required: false, granted: granted[permission] == true)
        }
        return required + optional
    }

    private func permissionCheck(
        _ permission: ExtensionPermission, required: Bool, granted: Bool
    ) -> ExtensionLifecycleCheck {
        check(
            "permission.\(permission.rawValue)", "\(permission.displayName) access",
            granted ? .passed : required ? .failed : .warning,
            granted ? "Granted." : permission.reason,
            granted ? nil : "ed permissions request \(permission.rawValue)")
    }

    private func toolChecks(
        _ entry: ExtensionRegistryEntry, rule: ToolRule
    ) async -> [ExtensionLifecycleCheck] {
        guard !entry.requiredTools.isEmpty else { return [] }
        var readiness: [(CLIToolSpec, ExtensionToolReadiness)] = []
        for tool in entry.requiredTools {
            readiness.append((tool, await environment.toolReadiness(tool.id)))
        }
        if rule == .any {
            let names = entry.requiredTools.map(\.displayName).joined(separator: " or ")
            let installed = readiness.compactMap { tool, state -> String? in
                guard case let .installed(version) = state else { return nil }
                return "\(tool.displayName) \(version)"
            }
            let errors = readiness.compactMap { _, state -> String? in
                guard case let .error(detail) = state else { return nil }
                return detail
            }
            let runtimePhase: ExtensionRuntimePhase =
                !installed.isEmpty ? .installed : errors.isEmpty ? .uninstalled : .error
            return [
                check(
                    "tool.provider", "Usage provider", installed.isEmpty ? .failed : .passed,
                    installed.isEmpty
                        ? errors.first ?? "Install and authenticate \(names)."
                        : "Ready: \(installed.joined(separator: ", ")).",
                    installed.isEmpty ? "ed tools ls" : nil, runtimePhase: runtimePhase)
            ]
        }
        return readiness.map { toolCheck($0.0, readiness: $0.1, required: true) }
    }

    private func optionalToolChecks(
        _ entry: ExtensionRegistryEntry
    ) async -> [ExtensionLifecycleCheck] {
        var checks: [ExtensionLifecycleCheck] = []
        for tool in entry.optionalTools {
            checks.append(
                toolCheck(
                    tool, readiness: await environment.toolReadiness(tool.id), required: false)
            )
        }
        return checks
    }

    private func toolCheck(
        _ tool: CLIToolSpec, readiness: ExtensionToolReadiness, required: Bool
    ) -> ExtensionLifecycleCheck {
        let runtimePhase: ExtensionRuntimePhase?
        if required {
            runtimePhase =
                switch readiness {
                case .installed: .installed
                case .uninstalled: .uninstalled
                case .error: .error
                }
        } else {
            runtimePhase = nil
        }
        return switch readiness {
        case let .installed(version):
            check(
                "tool.\(tool.id)", "\(tool.displayName) tool", .passed,
                "Installed and verified: \(version).", nil, runtimePhase: runtimePhase)
        case .uninstalled:
            check(
                "tool.\(tool.id)", "\(tool.displayName) tool",
                required ? .failed : .warning, tool.why, "ed tools install \(tool.id)",
                runtimePhase: runtimePhase)
        case let .error(detail):
            check(
                "tool.\(tool.id)", "\(tool.displayName) tool",
                required ? .failed : .warning, detail, "ed tools install \(tool.id)",
                runtimePhase: runtimePhase)
        }
    }

    private func helperCheck() -> ExtensionLifecycleCheck {
        let running = environment.helperRunning()
        return check(
            "helper", "Menu bar helper", running ? .passed : .failed,
            running
                ? "The Edith menu bar helper is running." : "The extension runtime is not running.",
            running ? nil : "ed app relaunch --yes")
    }

    private func machineCheck() -> ExtensionLifecycleCheck {
        let count = environment.machineCount()
        return check(
            "machines", "Configured machines", count > 0 ? .passed : .failed,
            count > 0 ? "Configured machines: \(count)." : "No SSH machines are configured.",
            count > 0 ? nil : "ed machines add --help")
    }

    private func adapterCheck(
        _ entry: ExtensionRegistryEntry, readiness: ExtensionAdapterReadiness
    ) -> ExtensionLifecycleCheck {
        let recovery = entry.lifecycle?.recovery.first?.command
        let prerequisite = entry.lifecycle?.prerequisites.first?.command
        return switch readiness {
        case let .ready(detail):
            check(
                "adapter.\(entry.id)", "Runtime adapter", .passed, detail, nil,
                runtimePhase: .installed)
        case let .degraded(detail):
            check(
                "adapter.\(entry.id)", "Runtime adapter", .warning, detail, recovery,
                runtimePhase: .installed)
        case let .needsSetup(detail):
            check("adapter.\(entry.id)", "Runtime adapter", .failed, detail, recovery)
        case let .uninstalled(detail):
            check(
                "adapter.\(entry.id)", "Runtime adapter", .failed, detail,
                prerequisite ?? recovery,
                runtimePhase: .uninstalled)
        case let .empty(detail):
            check(
                "adapter.\(entry.id)", "Runtime adapter", .passed, detail, nil,
                runtimePhase: .empty)
        case let .loading(detail):
            check(
                "adapter.\(entry.id)", "Runtime adapter", .skipped, detail, nil,
                runtimePhase: .loading)
        case let .unsupported(detail):
            check(
                "adapter.\(entry.id)", "Runtime adapter", .failed, detail, recovery,
                runtimePhase: .unsupported)
        case let .failed(detail):
            check(
                "backend.\(entry.id)", "Runtime adapter", .failed, detail, recovery,
                runtimePhase: .error)
        }
    }

    private func report(
        _ entry: ExtensionRegistryEntry, enabled: Bool, checks: [ExtensionLifecycleCheck]
    ) -> ExtensionLifecycleReport {
        let problems = checks.filter { $0.status == .warning || $0.status == .failed }
        let phase: ExtensionLifecyclePhase
        let runtimePhase = runtimePhase(checks)
        if !enabled {
            phase = .disabled
        } else if runtimePhase == .unsupported {
            phase = .unavailable
        } else if runtimePhase == .error {
            phase = .failed
        } else if runtimePhase == .loading {
            phase = .checking
        } else if checks.contains(where: { $0.status == .failed }) {
            phase = .needsSetup
        } else if checks.contains(where: { $0.status == .warning }) {
            phase = .degraded
        } else {
            phase = .ready
        }
        let issues = problems.map { item in
            ExtensionLifecycleIssue(
                id: item.id, title: item.title, detail: item.detail,
                recoveryCommand: item.recoveryCommand)
        }
        return ExtensionLifecycleReport(
            state: ExtensionLifecycleState(
                extensionID: entry.id, phase: phase, runtimePhase: runtimePhase,
                summary: summary(phase, runtimePhase: runtimePhase), issues: issues),
            checks: checks)
    }

    private func runtimePhase(_ checks: [ExtensionLifecycleCheck]) -> ExtensionRuntimePhase {
        let phases = Set(checks.compactMap(\.runtimePhase))
        for phase in [
            ExtensionRuntimePhase.unsupported, .error, .loading, .uninstalled, .empty,
        ] where phases.contains(phase) {
            return phase
        }
        return .installed
    }

    private func summary(
        _ phase: ExtensionLifecyclePhase, runtimePhase: ExtensionRuntimePhase
    ) -> String {
        switch phase {
        case .ready:
            runtimePhase == .empty
                ? "Enabled and ready; no content or sessions are available yet."
                : "Enabled and verified ready."
        case .degraded: "Ready with optional capabilities unavailable."
        case .needsSetup: "Enabled, but setup is incomplete."
        case .unavailable: "Required platform capabilities are unavailable."
        case .failed: "The extension runtime failed its health check."
        case .disabled: "Disabled; runtime checks reflect the current installation."
        case .checking, .enabled: phase.title
        }
    }

    private func check(
        _ id: String, _ title: String, _ status: ExtensionLifecycleCheckStatus, _ detail: String,
        _ recovery: String? = nil, runtimePhase: ExtensionRuntimePhase? = nil
    ) -> ExtensionLifecycleCheck {
        ExtensionLifecycleCheck(
            id: id, title: title, status: status, runtimePhase: runtimePhase, detail: detail,
            recoveryCommand: recovery)
    }

    private func names(_ capabilities: [PlatformCapability]) -> String {
        capabilities.map(\.rawValue).joined(separator: ", ")
    }
}
