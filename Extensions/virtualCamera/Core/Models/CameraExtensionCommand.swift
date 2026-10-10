import EdithExtensionSupport
import Foundation

public enum CameraExtensionIPC {
    public static let requestKey = "request"
    public static let requestIDKey = "requestID"
    public static let deadlineKey = "deadline"
    public static let snapshotKey = "snapshot"
    public static let okKey = "ok"
    public static let errorKey = "error"
}

public struct CameraExtensionSnapshot: Codable, Equatable, Sendable {
    public var phase: String
    public var title: String
    public var detail: String
    public var changed: Bool

    public init(phase: String, title: String, detail: String, changed: Bool) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.changed = changed
    }

    public var encoded: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String?) -> CameraExtensionSnapshot? {
        guard let text else { return nil }
        return try? JSONDecoder().decode(CameraExtensionSnapshot.self, from: Data(text.utf8))
    }

    public func resultPayload(requestID: String?, error: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [CameraExtensionIPC.okKey: error == nil]
        if let requestID { payload[CameraExtensionIPC.requestIDKey] = requestID }
        if let encoded { payload[CameraExtensionIPC.snapshotKey] = encoded }
        if let error { payload[CameraExtensionIPC.errorKey] = error }
        return payload
    }
}

public enum CameraExtensionRequest: String, Codable, Equatable, Sendable {
    case status
    case install
    case remove

    public var encoded: String? { rawValue }

    public static func decode(_ text: String) -> CameraExtensionRequest? {
        CameraExtensionRequest(rawValue: text)
    }
}

public struct CameraExtensionRuntimeRequest: Equatable, Sendable {
    public let request: CameraExtensionRequest
    public let requestID: String
    public let deadline: Date

    public init(
        request: CameraExtensionRequest, requestID: String = UUID().uuidString, deadline: Date
    ) {
        self.request = request
        self.requestID = requestID
        self.deadline = deadline
    }

    public init?(payload: [AnyHashable: Any]) {
        guard let text = payload[CameraExtensionIPC.requestKey] as? String,
            let request = CameraExtensionRequest.decode(text),
            let requestID = payload[CameraExtensionIPC.requestIDKey] as? String,
            UUID(uuidString: requestID) != nil,
            let deadline = payload[CameraExtensionIPC.deadlineKey] as? TimeInterval,
            deadline.isFinite
        else { return nil }
        self.init(
            request: request, requestID: requestID,
            deadline: Date(timeIntervalSince1970: deadline))
    }

    public var payload: [String: Any] {
        [
            CameraExtensionIPC.requestKey: request.rawValue,
            CameraExtensionIPC.requestIDKey: requestID,
            CameraExtensionIPC.deadlineKey: deadline.timeIntervalSince1970,
        ]
    }

    public func isLive(at now: Date = Date()) -> Bool { now < deadline }
}
