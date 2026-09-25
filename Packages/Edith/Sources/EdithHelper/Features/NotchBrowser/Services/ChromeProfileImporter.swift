import CryptoKit
import Foundation
import WebKit

struct ChromeProfileSnapshot: Sendable {
    let cookies: [ChromeCookie]
    let localStorage: [String: [String: String]]

    var siteCount: Int {
        Set(cookies.map { $0.host.hasPrefix(".") ? String($0.host.dropFirst()) : $0.host }).count
    }

    var newestCookieUpdate: Date? { cookies.map(\.updated).max() }
}

enum ChromeProfileImporter {
    static func snapshot(
        profile: ChromeProfile, userData: ChromeUserData, key: ChromeCookieKey,
        cookiesUpdatedAfter: Date?, includeLocalStorage: Bool
    ) throws -> ChromeProfileSnapshot {
        guard let database = userData.cookiesURL(for: profile) else {
            throw ChromeCookieReaderError.missingDatabase
        }
        let cookies = try ChromeCookieReader.read(
            database: database, key: key, updatedAfter: cookiesUpdatedAfter)
        let storage =
            includeLocalStorage
            ? LocalStorageSeed.importable(
                (try? ChromeLocalStorage.read(directory: userData.localStorageURL(for: profile)))
                    ?? [:])
            : [:]
        return ChromeProfileSnapshot(cookies: cookies, localStorage: storage)
    }

    static let cookieBatchSize = 200

    @MainActor
    static func apply(_ cookies: [ChromeCookie], to store: WKHTTPCookieStore) async -> Int {
        let converted = cookies.compactMap(\.httpCookie)
        var applied = 0
        while applied < converted.count {
            let batch = converted.dropFirst(applied).prefix(cookieBatchSize)
            await withTaskGroup(of: Void.self) { group in
                for cookie in batch.prefix(cookieBatchSize) {
                    group.addTask { @MainActor in await store.setCookie(cookie) }
                }
            }
            applied += batch.count
        }
        return applied
    }

    static func dataStoreIdentifier(profile: ChromeProfile, userData: ChromeUserData) -> UUID {
        let seed = "\(userData.root.standardizedFileURL.path)|\(profile.directory)"
        var bytes = Array(Array(SHA256.hash(data: Data(seed.utf8))).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14],
                bytes[15]
            ))
    }
}
