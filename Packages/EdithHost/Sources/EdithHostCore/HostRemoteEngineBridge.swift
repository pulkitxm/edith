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
        Task { @MainActor [endpoint] in
            let payload = try? await endpoint.invokeEngine(request)
            completion(
                (try? ExtensionEngineWire.encode(
                    ExtensionEngineReply(
                        token: request.token, ok: payload != nil, payload: payload ?? Data())))
                    ?? Data())
        }
    }

    @objc public func cancel(_ token: String) {
        guard token.utf8.count == 36, let token = UUID(uuidString: token) else { return }
        endpoint.cancelEngine(token)
    }
}
