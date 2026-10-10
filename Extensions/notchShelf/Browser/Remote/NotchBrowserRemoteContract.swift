import EdithExtensionSupport
import Foundation

struct NotchBrowserClientState: Codable, Sendable {
    let readiness: ChromeReadiness
    let profiles: [ChromeProfile]
    let avatars: [String: Data]
    let session: BrowserSession
    let searchEngine: String
    let dataStoreID: UUID?
    var leaseRevision: UInt64 = 0
    var leaseIDs: [UUID] = []
}

struct NotchBrowserImport: Codable, Sendable {
    let id: UUID
    let profile: ChromeProfile
    let dataStoreID: UUID
    let byteCount: Int
    let session: BrowserSession
    let lease: NotchBrowserLease
}

struct NotchBrowserLease: Codable, Sendable, Equatable {
    let id: UUID
    let ownershipID: UUID
    let presentationID: UUID
    let displayID: UInt32
    let generation: UUID
    let revision: UInt64
    let stateRevision: UInt64
    let profileID: String
    let expiresAt: Date
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
        case privacy, openInChrome, copyLink, held, downloadStart, downloadWrite, downloadCommit,
            downloadCancel
        case leaseRenew, leaseEnd
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
    var downloadID: UUID? = nil
    var fileName: String? = nil
    var byteOffset: UInt64? = nil
    var bytes: Data? = nil
    var lease: NotchBrowserLease? = nil
}
