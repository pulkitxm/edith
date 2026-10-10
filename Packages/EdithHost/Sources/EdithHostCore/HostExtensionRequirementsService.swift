import Foundation

public enum HostRequirementObservation: Equatable, Sendable {
    case available(String)
    case missing(String)
    case unknown(String)
    case unsupported(String)
}

public enum HostRequirementPackageState: Equatable, Sendable {
    case absent
    case incompatible
    case invalid(String)
    case installed(version: String, enabled: Bool, active: Bool)
}

public struct HostRequirementOwnerInspection: Sendable {
    public let owner: String
    public let phase: HostCoreReadinessRuntimePhase
    public let status: HostCoreReadinessCheckStatus
    public let detail: String
    public init(
        owner: String, phase: HostCoreReadinessRuntimePhase,
        status: HostCoreReadinessCheckStatus, detail: String
    ) {
        self.owner = owner; self.phase = phase; self.status = status; self.detail = detail
    }
}

public struct HostRequirementHerdrHost: Equatable, Sendable {
    public let id: String
    public let present: Bool
    public let liveSessions: Int
    public let error: String?
    public init(id: String, present: Bool, liveSessions: Int, error: String? = nil) {
        self.id = id; self.present = present; self.liveSessions = liveSessions; self.error = error
    }
}

@MainActor public struct HostExtensionRequirementsEnvironment {
    public let package: (String) async throws -> HostRequirementPackageState
    public let permission: (String) -> HostRequirementObservation
    public let capability: (String) -> HostRequirementObservation
    public let tool: (String) async throws -> HostRequirementObservation
    public let ownerInspection: (String) async throws -> HostRequirementOwnerInspection?
    public let herdrInventory: () async throws -> [HostRequirementHerdrHost]?
    public let activeSetup: ((String, Bool) async throws -> HostCoreReadinessSetup)?

    public init(
        package: @escaping (String) async throws -> HostRequirementPackageState,
        permission: @escaping (String) -> HostRequirementObservation,
        capability: @escaping (String) -> HostRequirementObservation,
        tool: @escaping (String) async throws -> HostRequirementObservation,
        ownerInspection: @escaping (String) async throws -> HostRequirementOwnerInspection?,
        herdrInventory: @escaping () async throws -> [HostRequirementHerdrHost]?,
        activeSetup: ((String, Bool) async throws -> HostCoreReadinessSetup)? = nil
    ) {
        self.package = package; self.permission = permission; self.capability = capability
        self.tool = tool; self.ownerInspection = ownerInspection;
        self.herdrInventory = herdrInventory
        self.activeSetup = activeSetup
    }
}

public struct HostRequirementSetupPreview: Sendable {
    public let id: String
    public let dependencies: [String]
    public let plannedTools: [String]
    public let toolRule: HostExtensionRequirement.ToolRule?
    public let requiredPermissions: [String]
    public let optionalPermissions: [String]
    public let instruction: String
}

@MainActor public struct HostExtensionRequirementsService {
    private let environment: HostExtensionRequirementsEnvironment
    public init(environment: HostExtensionRequirementsEnvironment) {
        self.environment = environment
    }

    public func inspect(id: String) async throws -> HostCoreReadinessReport {
        try await report(id: id, previewEnabled: false)
    }

    public func preview(id: String, installTools: Bool) async throws -> HostRequirementSetupPreview
    {
        let entry = try HostExtensionRequirementCatalog.entry(id: id)
        var planned: [String] = []
        if installTools, let original = entry.original {
            for tool in original.requiredTools {
                try Task.checkCancellation()
                if case .available = try await environment.tool(tool) {
                } else {
                    planned.append(tool)
                }
            }
        }
        return .init(
            id: id, dependencies: entry.dependencies, plannedTools: planned,
            toolRule: entry.original?.toolRule,
            requiredPermissions: entry.original?.requiredPermissions ?? [],
            optionalPermissions: entry.original?.optionalPermissions ?? [],
            instruction: entry.setupInstruction)
    }

    public func setup(id: String, dryRun: Bool, installTools: Bool) async throws
        -> HostCoreReadinessSetup
    {
        _ = try HostExtensionRequirementCatalog.entry(id: id)
        try Task.checkCancellation()
        if !dryRun {
            guard case let .installed(version, enabled, active) = try await environment.package(id),
                enabled, active, let setup = environment.activeSetup
            else {
                throw HostCLIError.rejected(
                    "No compatible authenticated active setup owner for " + id
                        + ". No tools, enablement or runtime were changed.")
            }
            let result = try await setup(id, installTools)
            try Task.checkCancellation()
            try result.validate(owner: id, dryRun: false, installTools: installTools)
            guard
                case let .installed(currentVersion, stillEnabled, stillActive) =
                    try await environment.package(
                        id),
                stillEnabled, stillActive, currentVersion == version
            else { throw HostCLIError.rejected("The setup owner is no longer active.") }
            return result
        }
        let preview = try await preview(id: id, installTools: installTools)
        let inspected = try await report(id: id, previewEnabled: true)
        let detail = [
            "Would enable " + id + "; dependencies: "
                + preview.dependencies.joined(separator: ", "),
            "Required permissions: " + preview.requiredPermissions.joined(separator: ", "),
            "Optional permissions: " + preview.optionalPermissions.joined(separator: ", "),
            "Tool rule: " + (preview.toolRule?.rawValue ?? "owner inspection required"),
            "Planned tools: " + preview.plannedTools.joined(separator: ", "), preview.instruction,
            "Preview only. No tools, permissions, services or enablement were changed.",
        ].joined(separator: "\n")
        let report = HostCoreReadinessReport(
            owner: id, id: id, title: inspected.title, state: inspected.state,
            checks: inspected.checks + [
                .init(
                    id: "setup.preview", title: "Original setup preview", status: .skipped,
                    detail: detail)
            ])
        return HostCoreReadinessSetup(
            owner: id, id: id, dryRun: true, changed: false, plannedTools: preview.plannedTools,
            installedTools: [], installFailures: [], report: report)
    }

    private func report(id: String, previewEnabled: Bool) async throws -> HostCoreReadinessReport {
        let entry = try HostExtensionRequirementCatalog.entry(id: id)
        try Task.checkCancellation()
        let package = try await environment.package(id)
        var enabled = false
        var active = false
        var checks: [HostCoreReadinessCheck] = []
        switch package {
        case .absent:
            checks.append(
                .init(
                    id: "package", title: "Signed package", status: .failed,
                    runtimePhase: .uninstalled, detail: "The extension package is absent.",
                    recoveryCommand: "ed extensions install " + id))
        case .incompatible:
            checks.append(
                .init(
                    id: "package", title: "Signed package", status: .failed,
                    runtimePhase: .unsupported,
                    detail: "No installed package is compatible with this host.",
                    recoveryCommand: "ed extensions update " + id))
        case let .invalid(detail):
            checks.append(
                .init(
                    id: "package", title: "Signed package", status: .failed,
                    runtimePhase: .error, detail: detail,
                    recoveryCommand: "ed extensions update " + id))
        case let .installed(version, selected, running):
            enabled = selected; active = running
            checks.append(
                .init(
                    id: "package", title: "Signed package", status: .passed,
                    runtimePhase: .installed,
                    detail: "Compatible package and signature verified: " + version))
        }
        checks.append(
            .init(
                id: "enabled", title: "Extension enabled",
                status: enabled || previewEnabled ? .passed : .skipped,
                detail: previewEnabled
                    ? "Preview assumes enablement; no preference was written."
                    : enabled
                        ? "Selected by the host." : "Disabled; readonly requirements still run."))
        if let original = entry.original {
            for capability in original.requiredCapabilities {
                checks.append(
                    check(
                        "capability." + capability, observation: environment.capability(capability),
                        required: true))
            }
            for capability in original.optionalCapabilities {
                checks.append(
                    check(
                        "capability." + capability, observation: environment.capability(capability),
                        required: false))
            }
            for permission in original.requiredPermissions {
                checks.append(
                    check(
                        "permission." + permission, observation: environment.permission(permission),
                        required: true,
                        recovery: "ed permissions request " + permission))
            }
            for permission in original.optionalPermissions {
                checks.append(
                    check(
                        "permission." + permission, observation: environment.permission(permission),
                        required: false,
                        recovery: "ed permissions request " + permission))
            }
            var requiredTools: [HostCoreReadinessCheck] = []
            for tool in original.requiredTools {
                try Task.checkCancellation()
                requiredTools.append(
                    check(
                        "tool." + tool, observation: try await environment.tool(tool),
                        required: true,
                        recovery: "ed tools install " + tool))
            }
            if original.toolRule == .any, !requiredTools.isEmpty {
                let passed = requiredTools.contains { $0.status == .passed }
                checks.append(
                    .init(
                        id: "tool.provider", title: "Usage provider",
                        status: passed ? .passed : .failed,
                        runtimePhase: passed ? .installed : .uninstalled,
                        detail: requiredTools.map { $0.title + ": " + $0.detail }.joined(
                            separator: "; "),
                        recoveryCommand: passed ? nil : "ed tools ls"))
            } else {
                checks += requiredTools
            }
            for tool in original.optionalTools {
                try Task.checkCancellation()
                checks.append(
                    check(
                        "tool." + tool, observation: try await environment.tool(tool),
                        required: false,
                        recovery: "ed tools install " + tool))
            }
            if original.requiresHelper {
                checks.append(
                    .init(
                        id: "helper", title: "Owned runtime", status: active ? .passed : .failed,
                        runtimePhase: active ? .installed : .loading,
                        detail: active
                            ? "The existing owning runtime is active."
                            : "The owning runtime is inactive; inspection did not start it."))
            }
        } else {
            checks.append(
                .init(
                    id: "original.registry", title: "Original registry", status: .skipped,
                    detail:
                        "No original registry entry. Requirements must come from pure owned inspection."
                ))
        }
        if id == "plugins" {
            for tool in ["node", "npx"] {
                try Task.checkCancellation()
                var observation = try await environment.tool(tool)
                if tool == "node", case let .available(version) = observation,
                    !HostRequirementToolProbe.nodeSupported(version)
                {
                    observation = .unsupported(
                        "Plugins installation requires Node.js 22.20 or later. Found " + version
                            + ". Browsing remains available.")
                }
                checks.append(
                    check(
                        "tool." + tool, observation: observation, required: true,
                        recovery: "ed tools ls"))
            }
        }
        if id == "herdr" {
            checks.append(try await herdrCheck())
        } else if let owned = try await environment.ownerInspection(id) {
            guard owned.owner == id, HostCoreReadinessReport.text(owned.detail) else {
                throw HostCLIError.rejected("Invalid pure owning requirement inspection.")
            }
            checks.append(
                .init(
                    id: "owner.inspection", title: "Pure owning inspection", status: owned.status,
                    runtimePhase: owned.phase, detail: owned.detail))
        } else {
            checks.append(
                .init(
                    id: "owner.inspection", title: "Pure owning inspection", status: .failed,
                    runtimePhase: .loading,
                    detail: "Pure owned inspection is unavailable. " + entry.setupInstruction))
        }
        try Task.checkCancellation()
        let failed = checks.filter { $0.status == .failed }
        let warning = checks.filter { $0.status == .warning }
        let phases = Set(checks.compactMap(\.runtimePhase))
        let runtime: HostCoreReadinessRuntimePhase =
            [.unsupported, .error, .loading, .uninstalled, .empty].first(where: phases.contains)
            ?? .installed
        let phase: HostCoreReadinessPhase =
            !enabled && !previewEnabled
            ? .disabled
            : runtime == .unsupported
                ? .unavailable
                : runtime == .error
                    ? .failed
                    : runtime == .loading
                        ? .checking
                        : !failed.isEmpty
                            ? .needsSetup
                            : !warning.isEmpty ? .degraded : .ready
        let issues = (failed + warning).map {
            HostCoreReadinessIssue(
                id: $0.id, title: $0.title, detail: $0.detail, recoveryCommand: $0.recoveryCommand)
        }
        let result = HostCoreReadinessReport(
            owner: id, id: id, title: entry.title,
            state: .init(
                extensionID: id, phase: phase, runtimePhase: runtime,
                summary: issues.first?.detail ?? "Original readonly requirements are satisfied.",
                issues: issues), checks: checks)
        try result.validate(owner: id)
        return result
    }

    private func check(
        _ id: String, observation: HostRequirementObservation, required: Bool,
        recovery: String? = nil
    ) -> HostCoreReadinessCheck {
        let status: HostCoreReadinessCheckStatus
        let runtime: HostCoreReadinessRuntimePhase?
        let detail: String
        switch observation {
        case let .available(value): status = .passed; runtime = nil; detail = value
        case let .missing(value):
            status = required ? .failed : .warning; runtime = .uninstalled; detail = value
        case let .unknown(value):
            status = required ? .failed : .warning; runtime = .loading; detail = value
        case let .unsupported(value):
            status = required ? .failed : .warning; runtime = .unsupported; detail = value
        }
        return .init(
            id: id, title: id, status: status, runtimePhase: required ? runtime : nil,
            detail: detail, recoveryCommand: status == .passed ? nil : recovery)
    }

    private func herdrCheck() async throws -> HostCoreReadinessCheck {
        guard let hosts = try await environment.herdrInventory() else {
            return check(
                "owner.inspection",
                observation: .unknown("Actual Herdr host inventory inspection is unavailable."),
                required: true)
        }
        guard hosts.count <= 256, Set(hosts.map(\.id)).count == hosts.count,
            hosts.allSatisfy({
                HostCoreReadinessReport.text($0.id) && (0...100_000).contains($0.liveSessions)
                    && ($0.error.map(HostCoreReadinessReport.text) ?? true)
            })
        else { throw HostCLIError.rejected("Invalid Herdr host inventory inspection.") }
        let installed = hosts.filter(\.present)
        let sessions = installed.reduce(0) { $0 + $1.liveSessions }
        let errors = hosts.compactMap(\.error)
        if installed.isEmpty {
            return check(
                "owner.inspection",
                observation: .missing(
                    "Herdr is not installed on this Mac or a configured machine."), required: true)
        }
        return .init(
            id: "owner.inspection", title: "Actual Herdr host inventory",
            status: errors.isEmpty ? .passed : .warning,
            runtimePhase: sessions == 0 ? .empty : .installed,
            detail: errors.isEmpty
                ? (sessions == 0
                    ? "Herdr is installed, but no live sessions were found."
                    : "Found \(sessions) live Herdr sessions.")
                : "Found \(sessions) live sessions; some hosts failed: "
                    + errors.joined(separator: "; "))
    }
}
