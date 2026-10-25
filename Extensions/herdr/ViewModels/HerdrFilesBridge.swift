import EdithExtensionFiles
import Foundation

@MainActor
final class HerdrFilesBridge: FinderBridgeTransport {
    static let progressOperation = "herdr.ui.files.progress"
    static let payloadLimit = 6 * 1_024 * 1_024

    private let client: HerdrUIClient
    let bridgePresentationID: UUID

    init(client: HerdrUIClient, presentationID: UUID) {
        self.client = client
        bridgePresentationID = presentationID
    }

    var filesOperation: String { "herdr.ui.files" }
    var previewOperation: String { "herdr.ui.files.preview" }
    var exportOperation: String { "herdr.ui.files.export" }
    var sessionOperation: String? { "herdr.ui.files.session" }

    func bridgeOwned<Value>(_ work: @escaping @MainActor () async throws -> Value) async throws
        -> Value
    {
        try await work()
    }

    func bridgeJob<Request: Encodable, Reply: Decodable>(
        _ operation: String, value: Request, progress: @escaping (FileOperationProgress?) -> Void
    ) async throws -> Reply {
        let payload = try JSONEncoder().encode(value)
        let poller: Task<Void, Never>? = (value as? MachineFileRequest).map { request in
            Task { [client] in
                let query = try? JSONEncoder().encode(request)
                guard let query else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard
                        let data = try? await client.perform(
                            Self.progressOperation, payload: query,
                            payloadLimit: Self.payloadLimit, replyLimit: Self.payloadLimit),
                        let state = try? JSONDecoder().decode(
                            FileOperationProgress?.self, from: data)
                    else { continue }
                    progress(state)
                }
            }
        }
        defer { poller?.cancel() }
        let data = try await client.perform(
            operation, payload: payload, payloadLimit: Self.payloadLimit,
            replyLimit: Self.payloadLimit)
        return try JSONDecoder().decode(Reply.self, from: data)
    }

    func bridgeRequest<Request: Encodable, Reply: Decodable>(
        _ operation: String, value: Request
    ) async throws -> Reply {
        let data = try await client.perform(
            operation, payload: JSONEncoder().encode(value), payloadLimit: Self.payloadLimit,
            replyLimit: Self.payloadLimit)
        return try JSONDecoder().decode(Reply.self, from: data)
    }

    func bridgeCleanup<Request: Encodable>(_ operation: String, value: Request) async {
        let _: Bool? = try? await bridgeRequest(operation, value: value)
    }
}
