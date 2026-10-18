import EdithExtensionSupport
import EdithHostCore
import Foundation

@MainActor enum SurfaceActionRejection {
    static func require(_ invoke: () async throws -> Data) async throws {
        do {
            _ = try await invoke()
            throw HostWorkerError.invalidResponse
        } catch ExtensionPeerError.rejected(_) {}
    }
}
