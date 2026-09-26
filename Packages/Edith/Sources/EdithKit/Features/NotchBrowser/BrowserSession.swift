import CoreGraphics
import Foundation

public struct BrowserSession: Codable, Equatable, Sendable {
    public var profile: String?
    public var profileName: String?
    public var tabs: [String]
    public var selected: Int
    public var width: Double?
    public var height: Double?

    public init(
        profile: String? = nil, profileName: String? = nil, tabs: [String] = [],
        selected: Int = 0, width: Double? = nil, height: Double? = nil
    ) {
        self.profile = profile
        self.profileName = profileName
        self.tabs = tabs
        self.selected = selected
        self.width = width
        self.height = height
    }

    public var size: CGSize? {
        guard let width, let height else { return nil }
        return CGSize(width: width, height: height)
    }

    public var attachedProfileName: String? {
        guard let profile else { return nil }
        return profileName ?? profile
    }
}

public struct BrowserSessionFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: BrowserSessionFile {
        BrowserSessionFile(
            url: DataRoot.support.appendingPathComponent("notch-browser/session.json"))
    }

    public func load() -> BrowserSession {
        guard let data = try? Data(contentsOf: url),
            let session = try? JSONDecoder().decode(BrowserSession.self, from: data)
        else { return BrowserSession() }
        return session
    }

    public func save(_ session: BrowserSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
