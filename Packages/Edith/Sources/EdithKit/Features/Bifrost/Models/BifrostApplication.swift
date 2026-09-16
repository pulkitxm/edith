import Foundation

public struct BifrostApplication: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let path: String
    public let bundleID: String?
    public let searchTarget: BifrostMatchTarget

    public var id: String { path }

    public init(name: String, path: String, bundleID: String? = nil) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
        searchTarget = BifrostMatchTarget(name)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case bundleID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            path: try container.decode(String.self, forKey: .path),
            bundleID: try container.decodeIfPresent(String.self, forKey: .bundleID))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(bundleID, forKey: .bundleID)
    }
}

public struct BifrostIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let generatedAt: Date
    public let applications: [BifrostApplication]

    public init(
        version: Int = BifrostIndex.currentVersion, generatedAt: Date,
        applications: [BifrostApplication]
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.applications = applications
    }

    public static let empty = BifrostIndex(generatedAt: .distantPast, applications: [])

    public var isUsable: Bool { version == Self.currentVersion && !applications.isEmpty }
}
