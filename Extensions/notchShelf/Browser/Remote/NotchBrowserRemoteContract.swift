import EdithExtensionSupport
import Foundation

struct NotchBrowserClientState: Codable, Sendable {
    let readiness: ChromeReadiness
    let profiles: [ChromeProfile]
    let avatars: [String: Data]
    let session: BrowserSession
    let searchEngine: String
    let dataStoreID: UUID?
}

struct NotchBrowserImport: Codable, Sendable {
    let id: UUID
    let profile: ChromeProfile
    let dataStoreID: UUID
    let byteCount: Int
    let session: BrowserSession
}

struct NotchBrowserImportChunk: Codable, Sendable {
    let id: UUID
    let offset: Int
    let nextOffset: Int
    let bytes: Data
}

struct NotchBrowserRemoteRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case read, importStart, importRead, importEnd, save, detach, makeDefault, downloadChrome
        case privacy, openInChrome, copyLink, held
    }
    let identity: NotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let operation: Operation
    var profileID: String? = nil
    var importID: UUID? = nil
    var offset: Int? = nil
    var session: BrowserSession? = nil
    var link: String? = nil
    var held: Bool? = nil
}
