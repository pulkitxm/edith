import Foundation

public struct SurfaceSourceChoice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public init(_ id: String, _ title: String) { self.id = id; self.title = title }
}
