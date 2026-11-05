import EdithExtensionSupport
import Foundation

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
}

public enum CameraExtensionRequest: String, Codable, Equatable, Sendable {
    case status
    case install
    case remove
}
