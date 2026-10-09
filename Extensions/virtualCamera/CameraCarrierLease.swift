import EdithExtensionSupport
import Foundation

@MainActor protocol CameraCarrierLease: AnyObject {
    func begin() async throws -> Bool
    func providerExited() async throws -> Bool
    func prepareMicrophone() async throws
    func retireMicrophone() async throws
    func release() async throws
}

@MainActor final class CameraPrivilegedLease: CameraCarrierLease {
    private let client: ExtensionPrivilegedClient
    init(host: String, source: URL, version: String) {
        client = ExtensionPrivilegedClient(
            owner: "virtualCamera", source: source, version: version,
            mode: .connectOnly(hostIdentifier: host))
    }
    func begin() async throws -> Bool { try await boolean("beginSession", field: "providerExited") }
    func providerExited() async throws -> Bool {
        try await boolean("providerStatus", field: "providerExited")
    }
    func prepareMicrophone() async throws {
        guard try await boolean("microphonePrepare", field: "ok") else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    func retireMicrophone() async throws {
        if try await boolean("microphoneDisable", field: "restartRequired") {
            throw CameraCarrierRestartRequired(
                message: "Restart macOS to finish disabling the meeting microphone.")
        }
    }
    func release() async throws { try await client.release() }
    private func boolean(_ command: String, field: String) async throws -> Bool {
        let data = try await client.invoke(command, payload: Data("{}".utf8))
        guard data.count <= 8192,
            let values = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            values.count == 1, let number = values[field] as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else { throw CocoaError(.coderReadCorrupt) }
        return number.boolValue
    }
}
