import Foundation
@MainActor enum SyntheticEndpoint {
    static var starts = 0
    static var continuation: CheckedContinuation<Data, any Error>?
}
struct ExtensionPeerEndpoint {
    init(namespace: String, owner: String, directory: URL) throws {}
    @MainActor func invoke(_ operation: String, payload: Data, timeout: Double) async throws -> Data
    {
        SyntheticEndpoint.starts += 1
        return try await withCheckedThrowingContinuation { SyntheticEndpoint.continuation = $0 }
    }
}
enum ExtensionPeerError: Error { case timedOut }
@MainActor final class ExtensionEngineClient {
    init?(bridge: NSObject, presentationID: UUID) {}
}
