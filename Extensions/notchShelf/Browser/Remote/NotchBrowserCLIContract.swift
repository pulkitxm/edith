import Foundation

struct NotchBrowserCommandLease: Codable, Equatable, Sendable {
    let id: UUID
    let ownershipID: UUID
    let presentationID: UUID
    let displayID: UInt32
    let expiresAt: Date
}

struct NotchBrowserQueuedCommand: Codable, Sendable {
    let id: UUID
    let leaseID: UUID
    let request: NotchBrowserRequest
    let deadline: Date
}

struct NotchBrowserCommandResult: Codable, Sendable {
    let id: UUID
    let snapshot: NotchBrowserSnapshot?
    let error: String?
}

extension NotchBrowserRequest {
    func validate() throws {
        func text(_ value: String?, maximum: Int) throws {
            guard
                value.map({ !$0.isEmpty && $0.utf8.count <= maximum && !$0.utf8.contains(0) })
                    ?? true
            else { throw NotchBrowserActionError("The browser request is invalid.") }
        }
        switch self {
        case .navigate(let address, let tab):
            try text(address, maximum: 16384); try text(tab, maximum: 64)
        case .newTab(let address): try text(address, maximum: 16384)
        case .profile(let name): try text(name, maximum: 512)
        case .reload(_, let tab), .copyLink(let tab), .close(let tab), .closeOthers(let tab),
            .closeRight(let tab), .duplicate(let tab):
            try text(tab, maximum: 64)
        case .status, .reopen, .sync, .detach: break
        }
    }
}
