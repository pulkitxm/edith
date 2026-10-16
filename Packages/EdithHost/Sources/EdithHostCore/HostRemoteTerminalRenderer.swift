import EdithExtensionSupport
import Foundation

public struct HostRemoteTerminalRenderer {
    public init() {}

    private var sequences: [UUID: UInt64] = [:]

    public mutating func release(_ presentationID: UUID) { sequences[presentationID] = nil }

    public mutating func response(
        _ request: HostTerminalUIRequest, session: UUID, owner: String,
        configuredRequest: HostExtensionContentRequest?,
        execute: (String, NSDictionary) throws -> NSDictionary
    ) throws -> Data {
        guard let configuredRequest, configuredRequest.extensionID == owner else {
            throw HostWorkerError.rejected
        }
        try request.validate(
            session: session, request: configuredRequest, operation: request.operation.rawValue)
        let context = NSMutableDictionary(dictionary: [
            "presentationID": request.request.presentationID.uuidString
        ])
        if let event = request.event {
            guard event.sequence > (sequences[request.request.presentationID] ?? 0) else {
                throw HostWorkerError.rejected
            }
            sequences[request.request.presentationID] = event.sequence
            context["payload"] = try event.encoded(presentationID: request.request.presentationID)
        }
        let result = try execute(request.operation.rawValue, context)
        let data = try JSONSerialization.data(withJSONObject: result)
        guard !data.isEmpty, data.count <= 1024 else { throw HostWorkerError.invalidResponse }
        if request.operation == .status {
            _ = try HostTerminalUIStatus.decode(
                data, presentationID: request.request.presentationID)
        } else {
            struct Reply: Decodable { let ok: Bool }
            guard Set(result.allKeys.compactMap { $0 as? String }) == ["ok"] else {
                throw HostWorkerError.invalidResponse
            }
            _ = try JSONDecoder().decode(Reply.self, from: data)
        }
        return data
    }
}
