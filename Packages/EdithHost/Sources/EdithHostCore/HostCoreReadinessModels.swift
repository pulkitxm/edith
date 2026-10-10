import Foundation

public enum HostCoreReadinessPhase: String, CaseIterable, Codable, Sendable {
    case disabled
    case checking
    case needsSetup
    case enabled
    case ready
    case degraded
    case unavailable
    case failed

    public var title: String {
        switch self {
        case .disabled: "Disabled"
        case .checking: "Checking"
        case .needsSetup: "Needs setup"
        case .enabled: "Enabled"
        case .ready: "Ready"
        case .degraded: "Degraded"
        case .unavailable: "Unavailable"
        case .failed: "Failed"
        }
    }
}

public enum HostCoreReadinessRuntimePhase: String, CaseIterable, Codable, Sendable {
    case installed
    case uninstalled
    case empty
    case loading
    case unsupported
    case error

    public var title: String {
        switch self {
        case .installed: "Installed"
        case .uninstalled: "Uninstalled"
        case .empty: "Empty"
        case .loading: "Loading"
        case .unsupported: "Unsupported"
        case .error: "Error"
        }
    }
}

public struct HostCoreReadinessIssue: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let recoveryCommand: String?

    public init(id: String, title: String, detail: String, recoveryCommand: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.recoveryCommand = recoveryCommand
    }
}

public struct HostCoreReadinessState: Codable, Equatable, Sendable {
    public let extensionID: String
    public let phase: HostCoreReadinessPhase
    public let runtimePhase: HostCoreReadinessRuntimePhase
    public let summary: String
    public let issues: [HostCoreReadinessIssue]

    public init(
        extensionID: String, phase: HostCoreReadinessPhase,
        runtimePhase: HostCoreReadinessRuntimePhase = .installed, summary: String,
        issues: [HostCoreReadinessIssue] = []
    ) {
        self.extensionID = extensionID
        self.phase = phase
        self.runtimePhase = runtimePhase
        self.summary = summary
        self.issues = issues
    }

    public static func preference(extensionID: String, enabled: Bool) -> Self {
        HostCoreReadinessState(
            extensionID: extensionID, phase: enabled ? .enabled : .disabled,
            runtimePhase: .loading,
            summary: enabled ? "Enabled; readiness has not been checked." : "Disabled.")
    }

    public static func loading(extensionID: String) -> Self {
        HostCoreReadinessState(
            extensionID: extensionID, phase: .checking, runtimePhase: .loading,
            summary: "Checking readiness.")
    }
}

public enum HostCoreReadinessCheckStatus: String, CaseIterable, Codable, Sendable {
    case passed
    case warning
    case failed
    case skipped
}

public struct HostCoreReadinessCheck: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: HostCoreReadinessCheckStatus
    public let runtimePhase: HostCoreReadinessRuntimePhase?
    public let detail: String
    public let recoveryCommand: String?

    public init(
        id: String, title: String, status: HostCoreReadinessCheckStatus,
        runtimePhase: HostCoreReadinessRuntimePhase? = nil, detail: String,
        recoveryCommand: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.runtimePhase = runtimePhase
        self.detail = detail
        self.recoveryCommand = recoveryCommand
    }
}

public struct HostCoreReadinessChecks: Codable, Equatable, Sendable {
    public let state: HostCoreReadinessState
    public let checks: [HostCoreReadinessCheck]

    public init(state: HostCoreReadinessState, checks: [HostCoreReadinessCheck]) {
        self.state = state
        self.checks = checks
    }

    public var verified: Bool { state.phase == .ready }
}
public struct HostCoreReadinessReport: Codable, Sendable {
    public let owner: String
    public let id: String
    public let title: String
    public let verified: Bool
    public let state: HostCoreReadinessState
    public let checks: [HostCoreReadinessCheck]
    public let remediation: [String]

    public init(
        owner: String, id: String, title: String, state: HostCoreReadinessState,
        checks: [HostCoreReadinessCheck]
    ) {
        self.owner = owner; self.id = id; self.title = title; self.state = state;
        self.checks = checks
        verified = state.phase == .ready
        remediation = state.issues.compactMap(\.recoveryCommand)
    }

    public func validate(owner expected: String) throws {
        guard owner == expected, id == expected, state.extensionID == expected,
            verified == (state.phase == .ready), checks.count <= 128, state.issues.count <= 128,
            Set(checks.map(\.id)).count == checks.count,
            Set(state.issues.map(\.id)).count == state.issues.count,
            !verified || checks.allSatisfy({ $0.status != .failed }),
            remediation == state.issues.compactMap(\.recoveryCommand),
            Self.text(title), Self.text(state.summary),
            checks.allSatisfy({
                Self.text($0.id) && Self.text($0.title) && Self.text($0.detail)
                    && ($0.recoveryCommand.map(Self.text) ?? true)
            }),
            state.issues.allSatisfy({
                Self.text($0.id) && Self.text($0.title) && Self.text($0.detail)
                    && ($0.recoveryCommand.map(Self.text) ?? true)
            })
        else { throw HostCLIError.rejected("Invalid owning extension readiness report.") }
    }

    static func text(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.utf8.contains(0)
    }

    public static func unavailable(state: HostCLIProviderState, title: String, detail: String)
        -> Self
    {
        let recovery =
            !state.installed || !state.compatible
            ? "ed extensions install " + state.id
            : !state.enabled
                ? "ed extensions enable " + state.id
                : "ed extensions update " + state.id
        let phase: HostCoreReadinessPhase =
            !state.enabled && state.installed ? .disabled : .unavailable
        let runtime: HostCoreReadinessRuntimePhase =
            !state.installed
            ? .uninstalled
            : !state.compatible ? .unsupported : state.running ? .installed : .loading
        let issue = HostCoreReadinessIssue(
            id: "owner.readiness", title: "Owning readiness provider",
            detail: detail, recoveryCommand: recovery)
        return Self(
            owner: state.id, id: state.id, title: title,
            state: .init(
                extensionID: state.id, phase: phase, runtimePhase: runtime,
                summary: detail, issues: [issue]),
            checks: [
                .init(
                    id: issue.id, title: issue.title, status: .failed,
                    runtimePhase: runtime, detail: detail, recoveryCommand: recovery)
            ])
    }
}

public struct HostCoreReadinessSetup: Codable, Sendable {
    public struct Failure: Codable, Sendable { public let id: String; public let detail: String }
    public let owner: String
    public let id: String
    public let dryRun: Bool
    public let changed: Bool
    public let plannedTools: [String]
    public let installedTools: [String]
    public let installFailures: [Failure]
    public let report: HostCoreReadinessReport

    public func validate(owner expected: String, dryRun expectedDryRun: Bool, installTools: Bool)
        throws
    {
        try report.validate(owner: expected)
        guard owner == expected, id == expected, dryRun == expectedDryRun,
            plannedTools.count <= 128, installedTools.count <= 128, installFailures.count <= 128,
            plannedTools.allSatisfy(HostCoreReadinessReport.text),
            installedTools.allSatisfy(HostCoreReadinessReport.text),
            installFailures.allSatisfy({
                HostCoreReadinessReport.text($0.id)
                    && HostCoreReadinessReport.text($0.detail)
            }),
            !dryRun || !changed && installedTools.isEmpty && installFailures.isEmpty,
            installTools || installedTools.isEmpty && installFailures.isEmpty
        else { throw HostCLIError.rejected("Invalid owning extension setup response.") }
    }
}
