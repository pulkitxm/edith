import AppKit
import EdithCore
import Foundation

public enum ExtensionAdapterReadiness: Equatable, Sendable {
    case ready(String)
    case degraded(String)
    case needsSetup(String)
    case failed(String)
}

public struct ExtensionLifecycleProbeEnvironment: Sendable {
    public var isEnabled: @Sendable (ExtensionRegistryEntry) -> Bool
    public var grantedPermissions: @Sendable () -> [ExtensionPermission: Bool]
    public var toolAvailable: @Sendable (String) -> Bool
    public var helperRunning: @Sendable () -> Bool
    public var platformCapabilities: PlatformCapabilities
    public var machineCount: @Sendable () -> Int
    public var adapterReadiness: @Sendable (String) async -> ExtensionAdapterReadiness?

    public init(
        isEnabled: @escaping @Sendable (ExtensionRegistryEntry) -> Bool,
        grantedPermissions: @escaping @Sendable () -> [ExtensionPermission: Bool],
        toolAvailable: @escaping @Sendable (String) -> Bool,
        helperRunning: @escaping @Sendable () -> Bool,
        platformCapabilities: PlatformCapabilities,
        machineCount: @escaping @Sendable () -> Int,
        adapterReadiness: @escaping @Sendable (String) async -> ExtensionAdapterReadiness?
    ) {
        self.isEnabled = isEnabled
        self.grantedPermissions = grantedPermissions
        self.toolAvailable = toolAvailable
        self.helperRunning = helperRunning
        self.platformCapabilities = platformCapabilities
        self.machineCount = machineCount
        self.adapterReadiness = adapterReadiness
    }

    public static let live = ExtensionLifecycleProbeEnvironment(
        isEnabled: { entry in
            SharedDefaults.store.object(forKey: entry.defaultsKey) as? Bool ?? false
        },
        grantedPermissions: { PermissionOperationCenter.application.grantedPermissions() },
        toolAvailable: { id in
            guard let tool = ToolProvisioning.spec(id: id),
                case let .executable(name, _) = tool.presenceStrategy
            else { return false }
            return CLIToolEnvironment.executable(named: name) != nil
        },
        helperRunning: {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: MainApp.statusBarBundleIdentifier
            ).isEmpty
        },
        platformCapabilities: .macOS,
        machineCount: { MachineRegistry.machines().count },
        adapterReadiness: { id in
            return switch id {
            case "companion": await companionReadiness()
            case "herdr": await herdrReadiness()
            default: nil
            }
        })

    private static func companionReadiness() async -> ExtensionAdapterReadiness {
        do {
            let health = try await CompanionClient(
                baseURL: CompanionClient.endpoint(override: nil)
            ).health()
            return companionReadiness(health)
        } catch {
            return .failed("Companion backend is unreachable: \(error.localizedDescription)")
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

    static func herdrReadiness(_ hosts: [HerdrHostSnapshot]) -> ExtensionAdapterReadiness {
        let installed = hosts.filter(\.herdrPresent)
        guard !installed.isEmpty else {
            return .needsSetup("Herdr is not installed on this Mac or a configured machine.")
        }
        let agents = installed.flatMap(\.agents)
        guard !agents.isEmpty else {
            return .needsSetup("Herdr is installed, but no live sessions were found.")
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
        "usage": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .any, adapter: false),
        "herdr": Policy(
            requiresHelper: false, requiresMachine: false, toolRule: .all, adapter: true),
        "quinjet": Policy(
            requiresHelper: false, requiresMachine: false, toolRule: .all, adapter: false),
        "system": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: false),
        "machines": Policy(
            requiresHelper: true, requiresMachine: true, toolRule: .all, adapter: false),
        "companion": Policy(
            requiresHelper: false, requiresMachine: false, toolRule: .all, adapter: true),
        "systemStats": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: false),
        "micMute": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: false),
        "lidAwake": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: false),
        "music": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: false),
        "calendar": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: false),
        "notchShelf": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: false),
        "clipboard": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: false),
        "focusDim": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: false),
        "presenter": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: false),
        "colorPicker": Policy(
            requiresHelper: true, requiresMachine: false, toolRule: .all, adapter: false),
    ]

    public let environment: ExtensionLifecycleProbeEnvironment

    public init(environment: ExtensionLifecycleProbeEnvironment = .live) {
        self.environment = environment
    }

    public func report(for entry: ExtensionRegistryEntry) async -> ExtensionLifecycleReport {
        guard environment.isEnabled(entry) else {
            return ExtensionLifecycleReport(
                state: .preference(extensionID: entry.id, enabled: false),
                checks: [
                    check(
                        "enabled", "Extension enabled", .skipped,
                        "Enable the extension before checking readiness.",
                        "ed extensions setup \(entry.id)")
                ])
        }
        guard let policy = Self.policies[entry.id] else {
            return ExtensionLifecycleReport(
                state: ExtensionLifecycleState(
                    extensionID: entry.id, phase: .failed,
                    summary: "No lifecycle adapter is registered.",
                    issues: [
                        ExtensionLifecycleIssue(
                            id: "adapter", title: "Missing lifecycle adapter",
                            detail: "The extension registry and lifecycle probe are out of sync.")
                    ]),
                checks: [])
        }

        var checks = [check("enabled", "Extension enabled", .passed, "Enabled in shared settings.")]
        checks.append(platformCheck(entry))
        checks.append(contentsOf: permissionChecks(entry))
        checks.append(contentsOf: toolChecks(entry, rule: policy.toolRule))
        if policy.requiresHelper { checks.append(helperCheck()) }
        if policy.requiresMachine { checks.append(machineCheck()) }
        if policy.adapter, let readiness = await environment.adapterReadiness(entry.id) {
            checks.append(adapterCheck(entry, readiness: readiness))
        }
        return report(entry, checks: checks)
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
        switch entry.availability(on: environment.platformCapabilities) {
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
                "Required capabilities are unavailable: \(names(capabilities)).")
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
    ) -> [ExtensionLifecycleCheck] {
        guard !entry.requiredTools.isEmpty else { return [] }
        let available = entry.requiredTools.filter { environment.toolAvailable($0.id) }
        if rule == .any {
            let names = entry.requiredTools.map(\.displayName).joined(separator: " or ")
            return [
                check(
                    "tool.provider", "Usage provider", available.isEmpty ? .failed : .passed,
                    available.isEmpty
                        ? "Install and authenticate \(names)."
                        : "Available: \(available.map(\.displayName).joined(separator: ", ")).",
                    available.isEmpty ? "ed tools ls" : nil)
            ]
        }
        return entry.requiredTools.map { tool in
            let found = available.contains(tool)
            return check(
                "tool.\(tool.id)", "\(tool.displayName) tool", found ? .passed : .failed,
                found ? "Found on Edith's PATH." : tool.why,
                found ? nil : "ed tools install \(tool.id)")
        }
    }

    private func helperCheck() -> ExtensionLifecycleCheck {
        let running = environment.helperRunning()
        return check(
            "helper", "Menu bar helper", running ? .passed : .failed,
            running
                ? "The Edith menu bar helper is running." : "The extension runtime is not running.",
            running ? nil : "ed app relaunch")
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
        return switch readiness {
        case let .ready(detail): check("adapter.\(entry.id)", "Runtime adapter", .passed, detail)
        case let .degraded(detail):
            check("adapter.\(entry.id)", "Runtime adapter", .warning, detail, recovery)
        case let .needsSetup(detail):
            check("adapter.\(entry.id)", "Runtime adapter", .failed, detail, recovery)
        case let .failed(detail):
            check("backend.\(entry.id)", "Runtime adapter", .failed, detail, recovery)
        }
    }

    private func report(
        _ entry: ExtensionRegistryEntry, checks: [ExtensionLifecycleCheck]
    ) -> ExtensionLifecycleReport {
        let problems = checks.filter { $0.status == .warning || $0.status == .failed }
        let phase: ExtensionLifecyclePhase
        if checks.contains(where: { $0.id == "platform" && $0.status == .failed }) {
            phase = .unavailable
        } else if checks.contains(where: { $0.id.hasPrefix("backend.") && $0.status == .failed }) {
            phase = .failed
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
                extensionID: entry.id, phase: phase, summary: summary(phase), issues: issues),
            checks: checks)
    }

    private func summary(_ phase: ExtensionLifecyclePhase) -> String {
        switch phase {
        case .ready: "Enabled and verified ready."
        case .degraded: "Ready with optional capabilities unavailable."
        case .needsSetup: "Enabled, but setup is incomplete."
        case .unavailable: "Required platform capabilities are unavailable."
        case .failed: "The extension runtime failed its health check."
        case .disabled, .checking, .enabled: phase.title
        }
    }

    private func check(
        _ id: String, _ title: String, _ status: ExtensionLifecycleCheckStatus, _ detail: String,
        _ recovery: String? = nil
    ) -> ExtensionLifecycleCheck {
        ExtensionLifecycleCheck(
            id: id, title: title, status: status, detail: detail, recoveryCommand: recovery)
    }

    private func names(_ capabilities: [PlatformCapability]) -> String {
        capabilities.map(\.rawValue).joined(separator: ", ")
    }
}
