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
    ) throws -> ScratchpadDocument {
        try request(.list, ScratchpadRequest(retention: retention, now: now))
    }

    public static func create(name: String? = nil, text: String = "", now: Date = Date()) throws
        -> ScratchpadDocument
    {
        try request(.create, ScratchpadRequest(text: text, name: name, now: now))
    }

    public static func update(_ selector: String, text: String, now: Date = Date()) throws
        -> ScratchpadDocument
    {
        try request(.update, ScratchpadRequest(selector: selector, text: text, now: now))
    }

    public static func rename(_ selector: String, to name: String) throws -> ScratchpadDocument {
        try request(.rename, ScratchpadRequest(selector: selector, name: name))
    }

    public static func duplicate(_ selector: String, now: Date = Date()) throws -> ScratchpadDocument {
        try request(.duplicate, ScratchpadRequest(selector: selector, now: now))
    }

    public static func remove(_ selector: String) throws -> ScratchpadDocument {
        try request(.remove, ScratchpadRequest(selector: selector))
    }

    public static func clear(_ selector: String, now: Date = Date()) throws -> ScratchpadDocument {
        try request(.clear, ScratchpadRequest(selector: selector, now: now))
    }

    public static func select(_ selector: String) throws -> ScratchpadDocument {
        try AgentPayload.decode(ScratchpadDocument.self, from: AgentClient.shared.performInternal(
            selectOperation, payload: AgentPayload.encode(ScratchpadRequest(selector: selector))))
    }

    private static func request(_ operation: ScratchpadOperation, _ request: ScratchpadRequest) throws
        -> ScratchpadDocument
    {
        try AgentPayload.decode(ScratchpadDocument.self, from: AgentClient.shared.perform(
            operation.descriptor.id, payload: AgentPayload.encode(request)))
    }
}
