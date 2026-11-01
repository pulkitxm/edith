import Foundation

public struct SurfaceSlider: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let icon: String
    public let value: Double
    public let field: String?

    public init(_ id: String, _ title: String, _ icon: String, value: Double, field: String? = nil)
    {
        self.id = id; self.title = title; self.icon = icon; self.value = value; self.field = field
    }

    func validate() throws {
        guard SurfaceSnapshot.validText(id, maximum: 512),
            SurfaceSnapshot.validText(title, maximum: 256),
            SurfaceSnapshot.validText(icon, maximum: 128),
            value.isFinite, (0...1).contains(value),
            field.map({ SurfaceSnapshot.validText($0, maximum: 80) }) ?? true
        else { throw ExtensionPeerError.invalidRequest }
    }
}
