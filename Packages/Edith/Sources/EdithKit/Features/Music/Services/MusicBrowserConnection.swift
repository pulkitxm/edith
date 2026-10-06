import Foundation
import WebKit

public enum MusicBrowserConnection {
    public static let youtubeHosts: Set<String> = [
        ".youtube.com", "youtube.com", "music.youtube.com", ".music.youtube.com",
    ]

    public static func profiles() throws -> [ChromeProfile] {
        try ChromeUserData.standard.profiles()
    }

    public static func cookies(profile: ChromeProfile, userData: ChromeUserData = .standard) throws
        -> [HTTPCookie]
    {
        guard let database = userData.cookiesURL(for: profile) else {
            throw ChromeCookieReaderError.missingDatabase
        }
        let key = try ChromeSafeStorage.keychainKey()
        return try ChromeCookieReader.read(
            database: database, key: key, allowedHosts: youtubeHosts
        ).compactMap(\.httpCookie)
    }

    @MainActor
    public static func importSession(profile: ChromeProfile, into store: WKWebsiteDataStore)
        async throws
    {
        let cookies = try await Task.detached { try cookies(profile: profile) }.value
        try await apply(cookies, to: store)
    }

    @MainActor
    static func apply(_ cookies: [HTTPCookie], to store: WKWebsiteDataStore) async throws {
        let cookies = cookies.filter { youtubeHosts.contains($0.domain) }
        guard
            cookies.contains(where: {
                ["SID", "__Secure-3PSID", "__Secure-1PSID"].contains($0.name)
            })
        else {
            throw MusicConnectionError.youtubeSignInRequired
        }
        await store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        for cookie in cookies { await store.httpCookieStore.setCookie(cookie) }
    }
}

public enum MusicConnectionError: LocalizedError {
    case youtubeSignInRequired
    case playerUnavailable
    case invalidLink

    public var errorDescription: String? {
        switch self {
        case .youtubeSignInRequired:
            "Sign in to YouTube Music in this Chrome profile, then connect again."
        case .playerUnavailable:
            "The Spotify player is missing from this build. Rebuild or update Edith."
        case .invalidLink: "Enter a Spotify track, album, playlist, or episode link."
        }
    }
}
