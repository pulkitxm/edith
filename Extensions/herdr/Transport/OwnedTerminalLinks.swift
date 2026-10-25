import AppKit
import EdithExtensionSupport
import Foundation
import GhosttyTerminal

struct OwnedTerminalLinkRequest: Codable {
    let session: OwnedTerminalHandle
    var value: String? = nil
    var untrusted: Bool? = nil
    var token: UUID? = nil
}

struct OwnedTerminalLinkReply: Codable {
    let token: UUID?
    let resolution: TerminalLinkResolution
}

@MainActor final class OwnedTerminalLinks {
    private struct Target { let session: OwnedTerminalHandle; let url: URL; let expires: Date }
    private var targets: [UUID: Target] = [:]
    var open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var handler: @MainActor (URL) -> String = {
        NSWorkspace.shared.urlForApplication(toOpen: $0)?.deletingPathExtension().lastPathComponent
            ?? "the default application"
    }
    var now: @MainActor () -> Date = { Date() }

    func execute(_ operation: String, payload: Data, descriptor: OwnedTerminalDescriptor) throws
        -> Data
    {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw ExtensionPeerError.invalidRequest
        }
        let request = try JSONDecoder().decode(OwnedTerminalLinkRequest.self, from: payload)
        guard request.session == descriptor.handle else { throw ExtensionPeerError.invalidRequest }
        targets = targets.filter { $0.value.expires > now() }
        switch operation {
        case OwnedTerminalSession.owner + ".terminal.link.resolve":
            guard Set(object.keys) == ["session", "value", "untrusted"],
                let value = request.value, !value.isEmpty, value.utf8.count <= 4096,
                !value.utf8.contains(0), let untrusted = request.untrusted, targets.count < 32
            else { throw ExtensionPeerError.invalidRequest }
            let resolution = TerminalLinkResolution.resolve(
                value, directory: descriptor.directory,
                untrusted: untrusted, allowsLocalFiles: descriptor.allowsLocalFileLinks,
                handler: handler)
            var token: UUID?
            if resolution.disposition != .deny, let url = URL(string: resolution.target) {
                let id = UUID()
                targets[id] = Target(
                    session: descriptor.handle, url: url, expires: now().addingTimeInterval(60))
                token = id
            }
            return try JSONEncoder().encode(
                OwnedTerminalLinkReply(token: token, resolution: resolution))
        case OwnedTerminalSession.owner + ".terminal.link.open":
            guard Set(object.keys) == ["session", "token"], let token = request.token,
                let target = targets[token], target.session == descriptor.handle
            else { throw ExtensionPeerError.invalidRequest }
            targets[token] = nil
            guard open(target.url) else { throw ExtensionPeerError.unavailable }
            return Data("{}".utf8)
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    func close(_ session: OwnedTerminalHandle) {
        targets = targets.filter { $0.value.session != session }
    }
    func stop() { targets.removeAll() }
}

extension OwnedTerminalClient {
    func resolveLink(_ value: String, untrusted: Bool) async throws -> OwnedTerminalLinkReply {
        let bytes = try JSONEncoder().encode(
            OwnedTerminalLinkRequest(
                session: descriptor.handle,
                value: value, untrusted: untrusted))
        let reply = try JSONDecoder().decode(
            OwnedTerminalLinkReply.self,
            from: await perform("link.resolve", payload: bytes))
        guard reply.resolution.target.utf8.count <= 4096,
            reply.resolution.detail.utf8.count <= 8192,
            (reply.resolution.disposition == .deny) == (reply.token == nil)
        else { throw ExtensionPeerError.invalidRequest }
        return reply
    }

    func openLink(_ token: UUID) async throws {
        _ = try await perform(
            "link.open",
            payload: JSONEncoder().encode(
                OwnedTerminalLinkRequest(session: descriptor.handle, token: token)))
    }
}
