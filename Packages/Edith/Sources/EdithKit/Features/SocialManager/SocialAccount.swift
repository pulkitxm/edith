import Foundation

public struct SocialPlatform: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var website: URL
    public var symbol: String

    public init(id: UUID = UUID(), name: String, website: URL, symbol: String = "globe") {
        self.id = id
        self.name = name
        self.website = website
        self.symbol = symbol
    }

    public static let presets: [SocialPlatform] = [
        SocialPlatform(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
            name: "Instagram", website: URL(string: "https://www.instagram.com")!, symbol: "camera"),
        SocialPlatform(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!,
            name: "Facebook", website: URL(string: "https://www.facebook.com")!, symbol: "person.2"),
        SocialPlatform(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!,
            name: "X / Twitter", website: URL(string: "https://x.com")!,
            symbol: "bubble.left.and.bubble.right"),
        SocialPlatform(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000004")!,
            name: "YouTube", website: URL(string: "https://www.youtube.com")!,
            symbol: "play.rectangle"),
        SocialPlatform(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000005")!,
            name: "LinkedIn", website: URL(string: "https://www.linkedin.com")!, symbol: "briefcase"
        ),
    ]

    public static let gmail = SocialPlatform(
        id: UUID(uuidString: "A0000000-0000-0000-0000-000000000006")!,
        name: "Gmail", website: URL(string: "https://mail.google.com")!, symbol: "envelope")

    public var isGoogleService: Bool {
        guard let host = website.host?.lowercased() else { return false }
        return ["google.com", "youtube.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public static func websiteURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: address), url.scheme?.lowercased() == "https",
            let host = url.host, !host.isEmpty, host.contains("."),
            url.user == nil, url.password == nil
        else { throw SocialAccountError.invalidWebsite }
        return url
    }
}

public struct SocialProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var badge: String
    public var email: String?
    public var avatarFilename: String?

    public init(
        id: UUID = UUID(), name: String, badge: String = "", email: String? = nil,
        avatarFilename: String? = nil
    ) {
        self.id = id
        self.name = name
        self.badge = badge
        self.email = email
        self.avatarFilename = avatarFilename
    }

    public var initials: String {
        if !badge.isEmpty { return String(badge.prefix(2)) }
        return String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

public struct SocialAccount: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let profileID: UUID
    public let platformID: UUID
    public var name: String
    public var badge: String
    public var avatarFilename: String?
    public var website: URL?
    public var browserSessionID: UUID?
    public var username: String?

    public init(
        id: UUID = UUID(), profileID: UUID, platformID: UUID, name: String, badge: String = "",
        avatarFilename: String? = nil, website: URL? = nil, browserSessionID: UUID? = nil,
        username: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.platformID = platformID
        self.name = name
        self.badge = badge
        self.avatarFilename = avatarFilename
        self.website = website
        self.browserSessionID = browserSessionID
        self.username = username
    }

    public var dataStoreID: UUID { browserSessionID ?? id }
    public var handle: String? { username.flatMap { $0.isEmpty ? nil : "@" + $0 } }

    public var initials: String {
        if !badge.isEmpty { return String(badge.prefix(2)) }
        return String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

public struct SocialAccountCatalog: Codable, Equatable, Sendable {
    public var profiles: [SocialProfile]
    public var platforms: [SocialPlatform]
    public var accounts: [SocialAccount]

    public init(
        profiles: [SocialProfile] = [], platforms: [SocialPlatform] = SocialPlatform.presets,
        accounts: [SocialAccount] = []
    ) {
        self.profiles = profiles
        self.platforms = platforms
        self.accounts = accounts
    }

    public func accounts(in profile: SocialProfile) -> [SocialAccount] {
        accounts.filter { $0.profileID == profile.id }
    }

    public func validated() throws -> Self {
        guard Set(platforms.map(\.id)).count == platforms.count,
            Set(profiles.map(\.id)).count == profiles.count,
            Set(accounts.map(\.id)).count == accounts.count,
            profiles.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ),
            platforms.allSatisfy({
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }),
            accounts.allSatisfy({ account in
                !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && platforms.contains { $0.id == account.platformID }
                    && profiles.contains { $0.id == account.profileID }
                    && (account.browserSessionID == nil
                        || account.browserSessionID == account.profileID)
            })
        else { throw SocialAccountError.invalidCatalog }
        for platform in platforms {
            _ = try SocialPlatform.websiteURL(platform.website.absoluteString)
        }
        for account in accounts {
            if let website = account.website {
                _ = try SocialPlatform.websiteURL(website.absoluteString)
            }
        }
        return self
    }
}

public enum SocialAccountError: LocalizedError {
    case invalidWebsite
    case invalidCatalog
    case emptyName

    public var errorDescription: String? {
        switch self {
        case .invalidWebsite: "Enter an HTTPS website address, such as instagram.com."
        case .invalidCatalog:
            "The social account list is invalid. Restore the account list before continuing."
        case .emptyName: "Enter a name for this profile, account or platform."
        }
    }
}
