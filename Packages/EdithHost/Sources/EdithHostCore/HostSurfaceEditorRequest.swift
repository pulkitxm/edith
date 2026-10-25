import EdithExtensionSupport
import Foundation

public enum HostSurfaceEditorKeys {
    public static let target = "surfaceEditorTarget"
    public static let widget = "surfaceEditorWidget"
}

public struct HostSurfaceEditorRequest: Equatable, Sendable {
    public let token: UUID
    public let target: SurfaceTarget
    public let tileID: String?

    public init(token: UUID = UUID(), target: SurfaceTarget, tileID: String? = nil) {
        self.token = token
        self.target = target
        self.tileID = tileID
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(target.rawValue, forKey: HostSurfaceEditorKeys.target)
        defaults.set(tileID ?? "", forKey: HostSurfaceEditorKeys.widget)
    }
}
