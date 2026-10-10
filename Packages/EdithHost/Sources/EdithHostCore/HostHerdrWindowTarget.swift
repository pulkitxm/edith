import Foundation

public struct HostHerdrWindowTarget: Codable, Equatable, Sendable {
    public let version: Int
    public let owner: String
    public let location: String
    public let target: String
    public let token: UUID
    public let title: String
    public let width: Int
    public let height: Int
    public let minimumWidth: Int
    public let minimumHeight: Int
    public let presented: Bool

    public func validate() throws {
        guard version == 1, owner == "herdr", ["herdr.agent", "herdr.space"].contains(location),
            !target.isEmpty, target.utf8.count <= 4096, !target.utf8.contains(0),
            !title.isEmpty, title.utf8.count <= 4096, !title.utf8.contains(0),
            (320...4096).contains(width), (240...4096).contains(height),
            (320...width).contains(minimumWidth), (240...height).contains(minimumHeight)
        else { throw HostWorkerError.rejected }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == [
                "version", "owner", "location", "target", "token", "title",
                "width", "height", "minimumWidth", "minimumHeight", "presented",
            ]
        else { throw HostWorkerError.rejected }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }

    public func matches(_ other: Self, presented: Bool) -> Bool {
        version == other.version && owner == other.owner && location == other.location
            && target == other.target && token == other.token && title == other.title
            && width == other.width && height == other.height
            && minimumWidth == other.minimumWidth && minimumHeight == other.minimumHeight
            && other.presented == presented
    }
}
