import Darwin
import EdithExtensionSupport
import Foundation
import ServiceManagement

enum LidAwakePrivilegedClientState: String, Equatable {
    case notRegistered, awaitingApproval, enabled, notFound
}

enum LidAwakePrivilegedClientError: LocalizedError {
    case helperUnavailable(LidAwakePrivilegedClientState)
    case connectionFailed(String)
    case remoteError(Error)
    case timedOut
    var errorDescription: String? {
        switch self {
        case .helperUnavailable(.awaitingApproval):
            "Approve Edith in System Settings > General > Login Items & Extensions, then try again."
        case .helperUnavailable(.notFound):
            "The privileged carrier is missing. Update Edith and download Lid Awake again."
        case .helperUnavailable:
            "Approve the privileged carrier from Lid Awake settings before changing lid sleep."
        case .connectionFailed(let detail): "Could not connect to the privileged carrier: " + detail
        case .remoteError(let error): error.localizedDescription
        case .timedOut: "The privileged carrier did not answer in time."
        }
    }
}

struct LidAwakeApplicationQuitContext: Sendable {
    let host: ExtensionProcessIdentity

    init?(input: NSDictionary) {
        guard
            Set(input.allKeys.compactMap { $0 as? String }) == [
                "operation", "reason", "hostPID", "hostGeneration",
            ],
            input["operation"] as? String == "prepareApplicationQuit",
            input["reason"] as? String == "applicationQuit",
            let pid = input["hostPID"] as? Int32,
            let generation = input["hostGeneration"] as? String,
            let host = ExtensionProcessIdentity.read(pid), host.generation == generation,
            pid == getppid()
        else { return nil }
        self.host = host
    }

    func validate() throws {
        guard host.isAlive, host.pid == getppid() else { throw ExtensionPeerError.invalidRequest }
    }

    func encoded() throws -> Data {
        try validate()
        return try JSONSerialization.data(withJSONObject: [
            "reason": "applicationQuit", "restoreOnQuit": false,
            "host": ["pid": host.pid, "generation": host.generation],
        ])
    }
}

@MainActor final class LidAwakePrivilegedClient {
    private let invoke: @MainActor (String, Data) async throws -> Data
    private let releaseLease: @MainActor () async throws -> Void
    private let invalidate: @MainActor () -> Void
    private let readState: @MainActor () -> LidAwakePrivilegedClientState
    private let approve: @MainActor () throws -> Void
    private var ownsLease = false

    convenience init(requestTimeout: Duration = .seconds(15)) {
        let bundle = Bundle(for: LidAwakeRuntimeMarker.self)
        let client = ExtensionPrivilegedClient(
            owner: "lidAwake",
            source: bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(
                "privileged.bundle"),
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "")
        self.init(
            state: {
                if ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil {
                    return .enabled
                }
                return switch client.status {
                case .enabled: .enabled
                case .requiresApproval: .awaitingApproval
                case .notFound: .notFound
                case .notRegistered: .notRegistered
                @unknown default: .notFound
                }
            }, invoke: { try await client.invoke($0, payload: $1) },
            release: { try await client.release() }, shutdown: { client.shutdown() },
            approve: { try client.requestApproval() })
    }

    init(
        state: @escaping @MainActor () -> LidAwakePrivilegedClientState,
        invoke: @escaping @MainActor (String, Data) async throws -> Data,
        release: @escaping @MainActor () async throws -> Void,
        shutdown: @escaping @MainActor () -> Void,
        approve: @escaping @MainActor () throws -> Void = { throw ExtensionPeerError.unavailable }
    ) {
        readState = state; self.invoke = invoke; releaseLease = release
        invalidate = shutdown; self.approve = approve
    }

    var state: LidAwakePrivilegedClientState { readState() }
    var isUsable: Bool { state == .enabled }
    var hasOwnedLease: Bool { ownsLease }
    func requestApproval() throws { try approve() }
    func setSleepDisabled(_ disable: Bool) async throws {
        if let error = Self.requestError(for: state) { throw error }
        ownsLease = true
        _ = try await invoke("setSleepDisabled", JSONEncoder().encode(disable))
    }
    func relinquishForApplicationQuit(_ context: LidAwakeApplicationQuitContext) async throws {
        try context.validate()
        guard ownsLease else { return }
        _ = try await invoke("extension.lifecycle.applicationQuit", context.encoded())
        try Task.checkCancellation()
        ownsLease = false
        invalidate()
    }
    func restoreOwnedState() async throws {
        if !ownsLease {
            if let error = Self.requestError(for: state) { throw error }
            ownsLease = true
            _ = try await invoke("status", Data())
        }
        try await release()
    }
    func release() async throws {
        try await releaseLease()
        ownsLease = false
    }
    func shutdown() { invalidate() }
    nonisolated static func requestError(for state: LidAwakePrivilegedClientState)
        -> LidAwakePrivilegedClientError?
    {
        state == .enabled ? nil : .helperUnavailable(state)
    }
}

final class LidAwakeRuntimeMarker: NSObject {}
