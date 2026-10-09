import Foundation

public struct SurfaceLayoutProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let target: SurfaceTarget
    public var layout: SurfaceLayout
    public init(id: UUID = UUID(), name: String, target: SurfaceTarget, layout: SurfaceLayout) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        self.target = target
        self.layout = layout.normalized()
    }
}
