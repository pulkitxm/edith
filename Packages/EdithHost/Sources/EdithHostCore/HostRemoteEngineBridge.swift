import EdithExtensionSupport
import Foundation

@MainActor
public final class HostRemoteEngineBridge: NSObject {
    private let endpoint: HostRemoteEndpoint
    private let presentationID: UUID

    public init(endpoint: HostRemoteEndpoint, presentationID: UUID) {
        self.endpoint = endpoint
        self.presentationID = presentationID
    }

    @objc public func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
        guard
            let request = try? ExtensionEngineWire.decode(ExtensionEngineRequest.self, from: data),
            request.presentationID == presentationID, (try? request.validate()) != nil
        else { completion(Data()); return }
        let reply = Completion(send: completion)
        endpoint.beginEngineRequest(request) { reply.finish($0) }
    }

    @objc public func cancel(_ token: String) {
        guard token.utf8.count == 36, let token = UUID(uuidString: token) else { return }
        endpoint.cancelEngine(token)
    }

    private final class Completion: @unchecked Sendable {
        private let send: (Data) -> Void
        init(send: @escaping (Data) -> Void) { self.send = send }
        @MainActor func finish(_ data: Data) { send(data) }
    }

}
