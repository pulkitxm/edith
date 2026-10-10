import EdithExtensionSupport
import Foundation
import WebKit

@MainActor final class MusicBrowserPresentation {
    private let connected: () -> Bool
    private let cookies: () async throws -> [HTTPCookie]
    private var token: MusicBrowserToken?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var commands: [MusicBrowserCommand] = []
    private var activity = Date()
    private(set) var metadata: MusicSurfacePlayback?
    private var stopped = false

    init(connected: @escaping () -> Bool, cookies: @escaping () async throws -> [HTTPCookie]) {
        self.connected = connected; self.cookies = cookies
    }

    func open() async throws -> MusicBrowserLease {
        guard !stopped, connected() else { throw ExtensionPeerError.unavailable }
        revoke()
        let generation = generation
        let values = try await cookies()
        try Task.checkCancellation()
        guard !stopped, connected(), generation == self.generation else {
            throw CancellationError()
        }
        let lease = MusicBrowserLease(
            id: UUID(), revision: UUID(),
            cookies: values.filter {
                MusicBrowserConnection.youtubeHosts.contains($0.domain)
                    && ($0.expiresDate.map { $0 > Date() } ?? true)
            }.map {
                MusicBrowserCookie(
                    name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                    secure: $0.isSecure, httpOnly: $0.isHTTPOnly,
                    expires: $0.expiresDate?.timeIntervalSince1970)
            })
        try lease.validate()
        token = .init(id: lease.id, revision: lease.revision)
        activity = Date()
        return lease
    }

    func validate(_ value: MusicBrowserToken) throws {
        guard !stopped, connected(), token?.id == value.id, token?.revision == value.revision,
            Date().timeIntervalSince(activity) <= 10
        else { throw ExtensionPeerError.unavailable }
    }

    func sync(_ value: MusicBrowserReport) throws -> MusicBrowserSync {
        try validate(value.token)
        guard value.cursor <= sequence, value.title.utf8.count <= 4096,
            value.artist.utf8.count <= 4096,
            value.key.utf8.count <= 8192,
            ![value.title, value.artist, value.key].contains(where: { $0.contains("\0") }),
            [value.elapsed, value.duration, value.volume].allSatisfy({ $0.isFinite && $0 >= 0 }),
            value.elapsed <= value.duration + 1, value.duration <= 604_800,
            (0...1).contains(value.volume)
        else { throw ExtensionPeerError.invalidRequest }
        commands.removeAll { $0.sequence <= value.cursor }
        activity = Date()
        metadata = .init(
            sourceID: "youtubeMusic", sourceTitle: "YouTube Music", trackKey: value.key,
            title: value.title, artist: value.artist, playing: value.playing,
            elapsed: value.elapsed,
            duration: value.duration, volume: value.volume)
        return .init(token: value.token, commands: commands)
    }

    func send(_ action: String, value: Double? = nil) throws {
        guard let token else { throw ExtensionPeerError.unavailable }
        try validate(token)
        guard
            ["toggle", "next", "previous", "backward", "forward", "seek", "volume", "reload"]
                .contains(action),
            value.map({ $0.isFinite && (0...1).contains($0) }) ?? true, commands.count < 64,
            !["seek", "volume"].contains(action) || value != nil
        else { throw ExtensionPeerError.invalidRequest }
        sequence &+= 1
        commands.append(.init(sequence: sequence, action: action, value: value))
    }

    func close(_ value: MusicBrowserToken) throws { try validate(value); revoke() }
    func revoke() {
        generation &+= 1; token = nil; sequence = 0; commands.removeAll(); metadata = nil
    }
    func stop() { stopped = true; revoke() }
}
