import Foundation

public enum HostTerminalUIAction: String, Codable, Sendable {
    case fontZoomIn, fontZoomOut, fontZoomReset
    case newTab, closeTab, nextTab, previousTab, windowClosed
}

public struct HostTerminalUIEvent: Codable, Equatable, Sendable {
    public let version: Int
    public let presentationID: UUID
    public let sequence: UInt64
    public let active: Bool
    public let key: Bool
    public let visible: Bool
    public let action: HostTerminalUIAction?

    public init(
        presentationID: UUID, sequence: UInt64, active: Bool, key: Bool, visible: Bool,
        action: HostTerminalUIAction? = nil
    ) {
        version = 1; self.presentationID = presentationID; self.sequence = sequence
        self.active = active; self.key = key; self.visible = visible; self.action = action
    }

    public func encoded(presentationID: UUID) throws -> Data {
        guard version == 1, self.presentationID == presentationID, sequence > 0 else {
            throw HostWorkerError.rejected
        }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 1024 else { throw HostWorkerError.rejected }
        return data
    }
}

public struct HostTerminalUIStatus: Codable, Equatable, Sendable {
    public let ok: Bool
    public let presentationID: UUID
    public let focused: Bool

    public init(presentationID: UUID, focused: Bool) {
        ok = true; self.presentationID = presentationID; self.focused = focused
    }

    public static func decode(_ data: Data, presentationID: UUID) throws -> Self {
        guard !data.isEmpty, data.count <= 1024 else { throw HostWorkerError.invalidResponse }
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(fields.keys) == ["ok", "presentationID", "focused"]
        else { throw HostWorkerError.invalidResponse }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.ok, result.presentationID == presentationID else {
            throw HostWorkerError.invalidResponse
        }
        return result
    }
}

public struct HostTerminalUIRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case update = "terminalUI"
        case status = "terminalUIStatus"
    }
    public let session: UUID
    public let request: HostExtensionContentRequest
    public let operation: Operation
    public let event: HostTerminalUIEvent?

    public init(
        session: UUID, request: HostExtensionContentRequest, operation: Operation,
        event: HostTerminalUIEvent? = nil
    ) {
        self.session = session; self.request = request; self.operation = operation
        self.event = event
    }

    public func validate(
        session: UUID, request: HostExtensionContentRequest, operation: String
    ) throws {
        try request.validate(extensionID: request.extensionID)
        guard self.session == session, self.request == request, Self.accepts(request),
            self.operation.rawValue == operation
        else { throw HostWorkerError.rejected }
        switch self.operation {
        case .update:
            guard let event else { throw HostWorkerError.rejected }
            _ = try event.encoded(presentationID: request.presentationID)
        case .status:
            guard event == nil else { throw HostWorkerError.rejected }
        }
    }

    public static func accepts(_ request: HostExtensionContentRequest) -> Bool {
        guard request.surface == nil, request.machinesWindow == nil,
            (try? request.validate(extensionID: request.extensionID)) != nil
        else { return false }
        switch (request.extensionID, request.location) {
        case ("terminal", "main"), ("herdr", "main"), ("herdr", "herdr.agent"),
            ("herdr", "herdr.space"), ("quinjet", "main"):
            return true
        default: return false
        }
    }

    public func encoded() throws -> Data {
        try validate(session: session, request: request, operation: operation.rawValue)
        let data = try JSONEncoder().encode(self)
        guard data.count <= 2048 else { throw HostWorkerError.rejected }
        return data
    }

    public static func decode(
        _ data: Data, session: UUID, request: HostExtensionContentRequest, operation: String
    ) throws -> Self {
        guard !data.isEmpty, data.count <= 2048 else { throw HostWorkerError.rejected }
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(fields.keys).isSubset(of: ["session", "request", "operation", "event"])
        else { throw HostWorkerError.rejected }
        if let event = fields["event"] as? [String: Any] {
            guard
                Set(event.keys).isSubset(of: [
                    "version", "presentationID", "sequence", "active", "key", "visible", "action",
                ])
            else { throw HostWorkerError.rejected }
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(session: session, request: request, operation: operation)
        return value
    }
}
