import EdithHostCore
import ExtensionMarketplace
import Foundation

@MainActor enum HostRequirementsCLIAdapter {
    struct Activation: Equatable {
        let enabled: Bool
        let active: Bool
        let version: String?
        let processIdentifier: Int32?
        let disablePending: Bool
        let removalPending: Bool

        var available: Bool {
            enabled && active && version != nil && (processIdentifier ?? 0) > 0
                && !disablePending && !removalPending
        }
    }

    struct Environment {
        let identity: HostIdentity
        let store: ExtensionPackageStore
        let hostABI: String
        let architecture: String
        let systemVersion: OperatingSystemVersion
        let expectedRoles: [String: Set<String>]
        let signaturePolicy: HostRequirementPackageInspection.SignaturePolicy
        let permissions: () -> [HostPermission: Bool]
        let activation: (String) -> Activation
        let tool: (String) async throws -> HostRequirementObservation
        let inspectOwner: (String) async throws -> HostCoreReadinessReport
        let setupOwner: (String, Bool) async throws -> HostCoreReadinessSetup
        var herdrInventory: () async throws -> [HostRequirementHerdrHost]? = { nil }
        var inspectPackage:
            (HostRequirementPackageInspection, String, Bool, Bool) throws ->
                HostRequirementPackageState = {
                    try $0.inspect(id: $1, enabled: $2, active: $3)
                }
    }

    static func make(
        marketplace: HostMarketplace, permissions: HostPermissions, hooks: HostCoreOwnerHooks,
        toolDirectories: [URL], expectedRoles: [String: Set<String>] = packagedRoles,
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        signaturePolicy: HostRequirementPackageInspection.SignaturePolicy? = nil,
        herdrInventory: @escaping () async throws -> [HostRequirementHerdrHost]? = { nil }
    ) throws -> HostCoreReadinessCLIBackend {
        guard toolDirectories.count <= 64,
            toolDirectories.allSatisfy({
                $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.contains(":")
            })
        else { throw HostCLIError.rejected("Invalid explicit requirement tool search path.") }
        let identity = marketplace.identity
        let policy: HostRequirementPackageInspection.SignaturePolicy
        if let signaturePolicy {
            policy = signaturePolicy
        } else if identity.development {
            policy = .development
        } else if let team = ExtensionCodeSignature.teamIdentifier() {
            policy = .publisher(teamIdentifier: team)
        } else {
            throw HostCLIError.rejected("The host publisher signature is unavailable.")
        }
        let probe = HostRequirementToolProbe(directories: toolDirectories)
        return make(
            environment: Environment(
                identity: identity, store: marketplace.packageStore,
                hostABI: HostContract.compatibility,
                architecture: architecture, systemVersion: systemVersion,
                expectedRoles: expectedRoles,
                signaturePolicy: policy, permissions: { permissions.granted },
                activation: { id in
                    let sessions = marketplace.sessions
                    return Activation(
                        enabled: sessions.enabledIDs.contains(id),
                        active: sessions.activeIDs.contains(id),
                        version: sessions.versions[id],
                        processIdentifier: sessions.processIdentifiers[id],
                        disablePending: sessions.pendingDisableIDs.contains(id),
                        removalPending: marketplace.pendingRemovalIDs.contains(id))
                }, tool: { try await probe.inspect(id: $0) },
                inspectOwner: { id in
                    try await hooks.readiness(
                        id: id, operation: "status",
                        title: HostExtensionRequirementCatalog.entry(id: id).title)
                },
                setupOwner: { id, installTools in
                    try await hooks.setup(id: id, dryRun: false, installTools: installTools)
                }, herdrInventory: herdrInventory))
    }

    static func make(environment: Environment) -> HostCoreReadinessCLIBackend {
        let service = HostExtensionRequirementsService(
            environment: .init(
                package: { try package(id: $0, environment: environment) },
                permission: { id in
                    guard let permission = HostPermission(rawValue: id) else {
                        return .unsupported("No original permission metadata for " + id + ".")
                    }
                    guard let granted = environment.permissions()[permission] else {
                        return .unknown(
                            permission.displayName + " access has not been captured. "
                                + permission.reason)
                    }
                    return granted
                        ? .available("Captured access is granted.") : .missing(permission.reason)
                },
                capability: {
                    HostRequirementPlatform.macOS(
                        capability: $0, version: environment.systemVersion)
                }, tool: environment.tool,
                ownerInspection: { id in
                    do {
                        guard let activation = try admission(id: id, environment: environment)
                        else { return nil }
                        let report = try await environment.inspectOwner(id)
                        try Task.checkCancellation()
                        try requireCurrent(id: id, activation: activation, environment: environment)
                        try report.validate(owner: id)
                        let status: HostCoreReadinessCheckStatus =
                            report.state.phase == .checking
                            ? .skipped
                            : report.checks.contains(where: { $0.status == .failed })
                                || ![.ready, .degraded].contains(report.state.phase)
                                ? .failed
                                : report.state.phase == .degraded
                                    || report.checks.contains(where: { $0.status == .warning })
                                    ? .warning : .passed
                        let detail =
                            ([report.state.summary]
                            + report.state.issues.map { $0.title + ": " + $0.detail }
                            + report.checks.filter { $0.status != .passed }.map {
                                $0.title + ": " + $0.detail
                            }).joined(
                                separator: "\n")
                        return .init(
                            owner: id, phase: report.state.runtimePhase, status: status,
                            detail: String(detail.prefix(1000)))
                    } catch is CancellationError { throw CancellationError() } catch {
                        return .init(
                            owner: id, phase: .error, status: .failed,
                            detail: "Authenticated readonly owner inspection failed: "
                                + String(error.localizedDescription.prefix(512)))
                    }
                }, herdrInventory: environment.herdrInventory,
                activeSetup: { id, installTools in
                    guard let activation = try admission(id: id, environment: environment) else {
                        throw HostCLIError.rejected(
                            "No current active setup owner for " + id
                                + ". No startup or enablement was attempted.")
                    }
                    let result = try await environment.setupOwner(id, installTools)
                    try Task.checkCancellation()
                    try requireCurrent(id: id, activation: activation, environment: environment)
                    try result.validate(owner: id, dryRun: false, installTools: installTools)
                    return result
                }))
        return HostCoreReadinessCLIBackend(
            entries: {
                HostExtensionRequirementCatalog.entries.map { .init(id: $0.id, title: $0.title) }
            },
            inspect: { id, _ in try await service.inspect(id: id) },
            setup: { try await service.setup(id: $0, dryRun: $1, installTools: $2) })
    }

    private static func package(id: String, environment: Environment) throws
        -> HostRequirementPackageState
    {
        try Task.checkCancellation()
        _ = try HostExtensionRequirementCatalog.entry(id: id)
        let activation = environment.activation(id)
        if activation.disablePending {
            return .invalid("The extension is pending disable; readonly requirements still run.")
        }
        if activation.removalPending {
            return .invalid("The extension is pending removal; readonly requirements still run.")
        }
        let inspector = HostRequirementPackageInspection(
            store: environment.store, hostABI: environment.hostABI,
            architecture: environment.architecture,
            systemVersion: environment.systemVersion.majorVersion,
            hostIdentifier: environment.identity.identifier,
            requiredRoles: environment.expectedRoles[id] ?? [], policy: environment.signaturePolicy)
        let result = try environment.inspectPackage(
            inspector, id, activation.enabled, activation.available)
        if case let .installed(version, enabled, active) = result {
            return .installed(
                version: version, enabled: enabled,
                active: active && activation.available && activation.version == version)
        }
        return result
    }

    private static func admission(id: String, environment: Environment) throws -> Activation? {
        let activation = environment.activation(id)
        guard activation.available,
            case let .installed(version, enabled, active) = try package(
                id: id, environment: environment),
            enabled, active, activation.version == version,
            environment.activation(id) == activation
        else { return nil }
        return activation
    }

    private static func requireCurrent(id: String, activation: Activation, environment: Environment)
        throws
    {
        guard environment.activation(id) == activation,
            try admission(id: id, environment: environment) == activation
        else {
            throw HostCLIError.rejected(
                "The owning version, activation or process changed before its result arrived.")
        }
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    static let packagedRoles: [String: Set<String>] = [
        "keepAwake": ["helper"],
        "audioMixer": ["app"],
        "focusDim": ["helper"],
        "windowSweaters": ["helper"],
        "micMute": ["helper"],
        "keystrokeHighlight": ["helper"],
        "presenter": ["helper"],
        "colorPicker": ["helper"],
        "systemStats": ["helper"],
        "emoji": ["helper"],
        "homebrew": ["app"],
        "calendar": ["app"],
        "jev": ["app"],
        "system": ["app"],
        "timeLapse": ["app"],
        "cleaner": ["app"],
        "appMaintenance": ["app"],
        "blitztree": ["app"],
        "plugins": ["app"],
        "notchShelf": ["helper"],
        "clipboard": ["helper"],
        "music": ["app"],
        "docs": ["app"],
        "latex": ["app"],
        "companion": ["app"],
        "terminal": ["app"],
        "studio": ["app"],
        "usage": ["app"],
        "bifrost": ["app"],
        "lidAwake": ["app", "privileged"],
        "attention": ["app"],
        "machines": ["app"],
        "downloads": ["app"],
        "seoAudit": ["app"],
        "virtualCamera": ["app", "privileged"],
        "codeStats": ["app"],
        "herdr": ["app"],
        "quinjet": ["app"],
        "database": ["app"],
    ]
}
