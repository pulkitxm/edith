import Foundation

struct EmbeddedMusicBrowserCookie: Codable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    var expires: Double?

    func validate() throws {
        guard
            [".youtube.com", "youtube.com", "music.youtube.com", ".music.youtube.com"].contains(
                domain),
            !name.isEmpty, name.utf8.count <= 256, value.utf8.count <= 8192,
            path.hasPrefix("/"), path.utf8.count <= 1024,
            [name, value, domain, path].allSatisfy({
                !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            }),
            expires.map({ $0.isFinite && $0 > Date().timeIntervalSince1970 }) ?? true
        else { throw CocoaError(.validationMissingMandatoryProperty) }
    }
}

struct EmbeddedMusicBrowserLease: Codable, Sendable {
    var id: UUID
    var revision: UUID
    var cookies: [EmbeddedMusicBrowserCookie]
    func validate() throws {
        guard cookies.count <= 256, try JSONEncoder().encode(self).count <= 524_288 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        for cookie in cookies { try cookie.validate() }
        guard
            cookies.contains(where: {
                ["SID", "__Secure-3PSID", "__Secure-1PSID"].contains($0.name)
            })
        else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
    }
}

struct EmbeddedMusicBrowserToken: Codable, Sendable {
    var id: UUID
    var revision: UUID
}

struct EmbeddedMusicBrowserCommand: Codable, Sendable {
    var sequence: UInt64
    var action: String
    var value: Double?
}

struct EmbeddedMusicBrowserReport: Codable, Sendable {
    var token: EmbeddedMusicBrowserToken
    var cursor: UInt64
    var title: String
    var artist: String
    var key: String
    var playing: Bool
    var elapsed: Double
    var duration: Double
    var volume: Double
}

struct EmbeddedMusicBrowserSync: Codable, Sendable {
    var token: EmbeddedMusicBrowserToken
    var commands: [EmbeddedMusicBrowserCommand]
}
