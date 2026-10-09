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

@MainActor final class LidAwakePrivilegedClient {
    private let client: ExtensionPrivilegedClient
    init(requestTimeout: Duration = .seconds(15)) {
        let bundle = Bundle(for: LidAwakeRuntimeMarker.self)
        client = .init(
            owner: "lidAwake",
            source: bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(
                "privileged.bundle"),
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "")
    }
    var state: LidAwakePrivilegedClientState {
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
    }
    var isUsable: Bool { state == .enabled }
    func requestApproval() throws { try client.requestApproval() }
    func setSleepDisabled(_ disable: Bool) async throws {
        guard let error = Self.requestError(for: state) else {
            _ = try await client.invoke("setSleepDisabled", payload: JSONEncoder().encode(disable));
            return
        }
        throw error
    }
    func release() async throws { try await client.release() }
    func shutdown() { client.shutdown() }
    nonisolated static func requestError(for state: LidAwakePrivilegedClientState)
        -> LidAwakePrivilegedClientError?
    {
        state == .enabled ? nil : .helperUnavailable(state)
    }
}

final class LidAwakeRuntimeMarker: NSObject {}
