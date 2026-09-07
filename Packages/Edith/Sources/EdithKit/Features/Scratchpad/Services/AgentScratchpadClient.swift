import EdithCore
import Foundation

public struct ScratchpadRequest: Codable, Sendable {
    public var selector: String = ""
    public var text: String = ""
    public var name: String?
    public var retention: ScratchpadRetention = .never
    public var now: Date = Date()
}

public enum AgentScratchpadClient {
    public static let operations: [ScratchpadOperation] = [
        .list, .create, .update, .rename, .duplicate, .remove, .clear,
    ]
    public static let selectOperation = "scratchpad.select"

    public static func load(
        retention: ScratchpadRetention = .never, now: Date = Date()
    ) async throws -> ScratchpadDocument {
        try await request(.list, ScratchpadRequest(retention: retention, now: now))
    }

    public static func create(name: String? = nil, text: String = "", now: Date = Date())
        async throws
        -> ScratchpadDocument
    {
        try await request(.create, ScratchpadRequest(text: text, name: name, now: now))
    }

    public static func update(_ selector: String, text: String, now: Date = Date()) async throws
        -> ScratchpadDocument
    {
        try await request(.update, ScratchpadRequest(selector: selector, text: text, now: now))
    }

    public static func rename(_ selector: String, to name: String) async throws
        -> ScratchpadDocument
    {
        try await request(.rename, ScratchpadRequest(selector: selector, name: name))
    }

    public static func duplicate(_ selector: String, now: Date = Date()) async throws
        -> ScratchpadDocument
    {
        try await request(.duplicate, ScratchpadRequest(selector: selector, now: now))
    }

    public static func remove(_ selector: String) async throws -> ScratchpadDocument {
        try await request(.remove, ScratchpadRequest(selector: selector))
    }

    public static func clear(_ selector: String, now: Date = Date()) async throws
        -> ScratchpadDocument
    {
        try await request(.clear, ScratchpadRequest(selector: selector, now: now))
    }

    public static func select(_ selector: String) async throws -> ScratchpadDocument {
        try AgentPayload.decode(
            ScratchpadDocument.self,
            from: await AgentClient.shared.performInternalAsync(
                selectOperation, payload: AgentPayload.encode(ScratchpadRequest(selector: selector))
            ))
    }

    private static func request(_ operation: ScratchpadOperation, _ request: ScratchpadRequest)
        async throws
        -> ScratchpadDocument
    {
        try AgentPayload.decode(
            ScratchpadDocument.self,
            from: await AgentClient.shared.performAsync(
                operation.descriptor.id, payload: AgentPayload.encode(request)))
    }
}
