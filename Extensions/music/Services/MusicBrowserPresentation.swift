import EdithExtensionSupport
import Foundation
import WebKit

@MainActor final class MusicBrowserPresentation {
    private let connected: () -> Bool
    private let cookies: () async throws -> [HTTPCookie]
    private let store: () -> WKWebsiteDataStore?
    private var commits: [UUID: Task<Void, Error>] = [:]
    private var token: MusicBrowserToken?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var commands: [MusicBrowserCommand] = []
    private var activity = Date()
    private var playback: MusicSurfacePlayback?
    var metadata: MusicSurfacePlayback? {
        guard token != nil else { return nil }
        guard !stopped, connected(), Date().timeIntervalSince(activity) <= 10 else {
            revoke(); return nil
        }
        return playback
    }
    private var stopped = false

    init(
        connected: @escaping () -> Bool, cookies: @escaping () async throws -> [HTTPCookie],
        store: @escaping () -> WKWebsiteDataStore? = { nil }
    ) {
        self.connected = connected; self.cookies = cookies; self.store = store
    }

    func open() async throws -> MusicBrowserLease {
        guard !stopped, connected() else { throw ExtensionPeerError.unavailable }
        revoke()
        let generation = generation
        await drain()
        try Task.checkCancellation()
        guard !stopped, connected(), generation == self.generation else {
            throw CancellationError()
        }
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
                    expires: $0.expiresDate?.timeIntervalSince1970,
                    sameSite: $0.properties?[.sameSitePolicy] as? String)
            })
        guard
            lease.cookies.contains(where: {
                ["SID", "__Secure-3PSID", "__Secure-1PSID"].contains($0.name)
            })
        else { throw MusicConnectionError.youtubeSignInRequired }
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
        playback = .init(
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

    func commit(_ lease: MusicBrowserLease) async throws {
        try validate(.init(id: lease.id, revision: lease.revision))
        try lease.validate(requireSignIn: false)
        guard let store = store() else { throw ExtensionPeerError.unavailable }
        guard commits.isEmpty else { throw ExtensionPeerError.invalidRequest }
        let generation = generation
        let native = try lease.cookies.map { try $0.nativeCookie() }
        let id = UUID()
        let task = Task { [weak self] in
            if native.isEmpty {
                try Task.checkCancellation()
                guard let self, !self.stopped, generation == self.generation, self.connected()
                else { throw CancellationError() }
                await store.removeData(
                    ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
            }
            let current = await store.httpCookieStore.allCookies()
            let keys = Set(native.map { $0.domain + "\0" + $0.path + "\0" + $0.name })
            for cookie in current
            where MusicBrowserConnection.youtubeHosts.contains(cookie.domain)
                && !keys.contains(cookie.domain + "\0" + cookie.path + "\0" + cookie.name)
            {
                try Task.checkCancellation()
                guard let self, !self.stopped, generation == self.generation, self.connected()
                else { throw CancellationError() }
                await store.httpCookieStore.deleteCookie(cookie)
            }
            for cookie in native {
                try Task.checkCancellation()
                guard let self, !self.stopped, generation == self.generation, self.connected()
                else { throw CancellationError() }
                await store.httpCookieStore.setCookie(cookie)
            }
            try Task.checkCancellation()
            guard let self, !self.stopped, generation == self.generation, self.connected() else {
                throw CancellationError()
            }
        }
        commits[id] = task
        defer { commits[id] = nil }
        try await withTaskCancellationHandler(
            operation: { try await task.value }, onCancel: { task.cancel() })
    }

    func drain() async { for task in Array(commits.values) { _ = try? await task.value } }

    func close(_ value: MusicBrowserToken) throws { try validate(value); revoke() }
    func revoke() {
        generation &+= 1; token = nil; sequence = 0; commands.removeAll(); playback = nil
        for task in commits.values { task.cancel() }
    }
    func stop() { stopped = true; revoke() }
}
