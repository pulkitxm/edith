import AppKit
import CryptoKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI
import WebKit

@MainActor @Observable
final class EmbeddedMusicBrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static var sessions: [UUID: EmbeddedMusicBrowserSession] = [:]
    private static var closing: [UUID: Task<Void, Never>] = [:]
    let lease: EmbeddedMusicBrowserLease
    let webView: WKWebView
    let store: WKWebsiteDataStore
    private let invoke: (String, Data) async throws -> Data
    private var cursor: UInt64 = 0
    private var cookieSignature: Data?
    private var heartbeat: Task<Void, Never>?
    private(set) var stopped = false
    var error: String?
    private var external: [UUID: Task<Void, Never>] = [:]
    private var loadingTask: Task<Void, Error>?

    init(lease: EmbeddedMusicBrowserLease, invoke: @escaping (String, Data) async throws -> Data)
        throws
    {
        try lease.validate()
        self.lease = lease; self.invoke = invoke
        store = .nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        Self.sessions[lease.id] = self
    }

    private var token: EmbeddedMusicBrowserToken { .init(id: lease.id, revision: lease.revision) }

    func start(loadHome: Bool = true) async throws {
        guard !stopped else { throw CancellationError() }
        guard loadingTask == nil, heartbeat == nil else { throw ExtensionPeerError.invalidRequest }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            for value in self.lease.cookies {
                try Task.checkCancellation()
                guard !self.stopped else { throw CancellationError() }
                let cookie = try value.nativeCookie()
                await self.store.httpCookieStore.setCookie(cookie)
            }
            try Task.checkCancellation()
            guard !self.stopped else { throw CancellationError() }
            if loadHome {
                self.webView.load(URLRequest(url: URL(string: "https://music.youtube.com")!))
            }
        }
        loadingTask = task
        defer { loadingTask = nil }
        try await withTaskCancellationHandler(
            operation: { try await task.value }, onCancel: { task.cancel() })
        guard !stopped else { throw CancellationError() }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled, let self, !self.stopped {
                do {
                    try await self.synchronize()
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    if !Task.isCancelled, !self.stopped {
                        self.error = error.localizedDescription; self.stop()
                    }
                    return
                }
            }
        }
    }

    static func isYoutubePage(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil
            && ["music.youtube.com", "www.youtube.com", "consent.youtube.com"].contains(
                url.host ?? "")
    }

    static func isExternal(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil
            && url.absoluteString.utf8.count <= 3500
    }

    func synchronize() async throws {
        guard !stopped else { throw CancellationError() }
        var metadata: [String: Any] = [:]
        if let url = webView.url, Self.isYoutubePage(url) {
            metadata =
                try await webView.evaluateJavaScript(
                    """
                    (() => { const video = document.querySelector('video');
                        if (!video) return {};
                        return { key: video.currentSrc || location.href,
                            title: document.querySelector('ytmusic-player-bar .title')?.textContent || document.title,
                            artist: document.querySelector('ytmusic-player-bar .byline')?.textContent || '',
                            playing: !video.paused, elapsed: video.currentTime,
                            duration: Number.isFinite(video.duration) ? video.duration : 0,
                            volume: video.volume }; })()
                    """) as? [String: Any] ?? [:]
        }
        let report = EmbeddedMusicBrowserReport(
            token: token, cursor: cursor,
            title: metadata["title"] as? String ?? "YouTube Music",
            artist: metadata["artist"] as? String ?? "",
            key: metadata["key"] as? String ?? "", playing: metadata["playing"] as? Bool ?? false,
            elapsed: metadata["elapsed"] as? Double ?? 0,
            duration: metadata["duration"] as? Double ?? 0,
            volume: metadata["volume"] as? Double ?? 0.7)
        let data = try await invoke("music.ui.youtube.sync", JSONEncoder().encode(report))
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let reply = try JSONDecoder().decode(EmbeddedMusicBrowserSync.self, from: data)
        guard reply.token.id == lease.id, reply.token.revision == lease.revision,
            reply.commands.count <= 64
        else {
            throw ExtensionPeerError.invalidRequest
        }
        for command in reply.commands {
            guard command.sequence == cursor + 1 else { throw ExtensionPeerError.invalidRequest }
            if command.action == "reload" {
                webView.reload(); error = nil
            } else {
                guard let url = webView.url, Self.isYoutubePage(url) else {
                    throw ExtensionPeerError.unavailable
                }
                let script: String
                switch command.action {
                case "toggle": script = "video.paused ? video.play() : video.pause()"
                case "next":
                    script = "document.querySelector('ytmusic-player-bar #next-button')?.click()"
                case "previous":
                    script =
                        "document.querySelector('ytmusic-player-bar #previous-button')?.click()"
                case "backward": script = "video.currentTime = Math.max(0, video.currentTime - 15)"
                case "forward":
                    script = "video.currentTime = Math.min(video.duration, video.currentTime + 15)"
                case "seek", "volume":
                    guard let value = command.value, value.isFinite, (0...1).contains(value) else {
                        throw ExtensionPeerError.invalidRequest
                    }
                    script =
                        command.action == "seek"
                        ? "video.currentTime = video.duration * \(value)"
                        : "video.volume = \(value)"
                default: throw ExtensionPeerError.invalidRequest
                }
                _ = try await webView.evaluateJavaScript(
                    "(() => { const video = document.querySelector('video'); if (video) { \(script); } })()"
                )
            }
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            cursor = command.sequence
        }
        try await persistCookies()
    }

    private func persistCookies() async throws {
        let cookies = await store.httpCookieStore.allCookies()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let values = cookies.filter {
            [".youtube.com", "youtube.com", "music.youtube.com", ".music.youtube.com"].contains(
                $0.domain)
                && ($0.expiresDate.map { $0 > Date() } ?? true)
        }.map {
            EmbeddedMusicBrowserCookie(
                name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                secure: $0.isSecure, httpOnly: $0.isHTTPOnly,
                expires: $0.expiresDate?.timeIntervalSince1970,
                sameSite: $0.properties?[.sameSitePolicy] as? String)
        }.sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
        let update = EmbeddedMusicBrowserLease(
            id: lease.id, revision: lease.revision, cookies: values)
        try update.validate(requireSignIn: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(update)
        let signature = Data(SHA256.hash(data: data))
        if cookieSignature != signature {
            _ = try await invoke("music.ui.youtube.cookies", data)
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            cookieSignature = signature
        }
    }

    private func openExternal(_ url: URL) {
        guard !stopped, Self.isExternal(url), external.count < 4 else { return }
        if url.host == "accounts.google.com" {
            error = "Sign in in Chrome, then reconnect your YouTube Music session."
        }
        let id = UUID()
        external[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.external[id] = nil }
            do {
                _ = try await self.invoke(
                    "music.ui.youtube.external",
                    JSONEncoder().encode([
                        "id": self.lease.id.uuidString, "revision": self.lease.revision.uuidString,
                        "url": url.absoluteString,
                    ]))
            } catch {
                if !self.stopped, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        guard !stopped, let url = navigationAction.request.url else { return .cancel }
        if url.absoluteString == "about:blank" { return .allow }
        if navigationAction.targetFrame?.isMainFrame == false {
            return url.scheme == "https" && url.user == nil && url.password == nil
                ? .allow : .cancel
        }
        if Self.isYoutubePage(url) { return .allow }
        openExternal(url)
        if url.host == "accounts.google.com" {
            error = "Sign in in Chrome, then reconnect your YouTube Music session."
        }
        return .cancel
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            openExternal(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if !stopped, (error as NSError).code != NSURLErrorCancelled {
            self.error = "YouTube Music could not load. Check your connection and reload."
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !stopped else { return }
        error = "YouTube Music stopped. Reload to reconnect."
        webView.stopLoading()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; loadingTask?.cancel(); heartbeat?.cancel(); cookieSignature = nil
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        Self.sessions[lease.id] = nil
        let loading = loadingTask; let heartbeat = heartbeat; let tasks = Array(external.values)
        for task in tasks { task.cancel() }
        external.removeAll()
        let view = webView; let store = store; let invoke = invoke; let token = token
        Self.closing[lease.id] = Task {
            await view.setAllMediaPlaybackSuspended(true)
            await view.closeAllMediaPresentations()
            _ = try? await loading?.value
            await heartbeat?.value
            for task in tasks { await task.value }
            await store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            _ = try? await invoke("music.ui.youtube.close", JSONEncoder().encode(token))
            Self.closing[lease.id] = nil
        }
    }

    static var current: EmbeddedMusicBrowserSession? { sessions.values.first { !$0.stopped } }

    static func stopAll() { for session in Array(sessions.values) { session.stop() } }
    static func drainAll() async { for task in Array(closing.values) { await task.value } }
}

private struct EmbeddedMusicNativeBrowser: NSViewRepresentable {
    let session: EmbeddedMusicBrowserSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) {}
}

struct EmbeddedMusicYoutubeWebView: View {
    @State private var session: EmbeddedMusicBrowserSession?
    @State private var failure: String?
    var body: some View {
        VStack(spacing: 0) {
            if let message = session?.error ?? failure { PageNotice(message, tone: .error) }
            if let session, !session.stopped {
                EmbeddedMusicNativeBrowser(session: session)
            } else if failure == nil {
                LoadingIndicator()
            }
        }
        .pageTask(id: EmbeddedMusicAccounts.shared.youtubePresentationRevision) {
            failure = nil
            do {
                if let current = EmbeddedMusicBrowserSession.current { session = current; return }
                let remote = EmbeddedMusicRemote.shared
                let data = try await remote.dataRequest("music.ui.youtube.open")
                let lease = try JSONDecoder().decode(EmbeddedMusicBrowserLease.self, from: data)
                let next = try EmbeddedMusicBrowserSession(lease: lease) {
                    [weak remote] operation, payload in
                    guard let remote else { throw CancellationError() }
                    return try await remote.dataRequest(operation, payload: payload)
                }
                session = next
                do { try await next.start() } catch { next.stop(); throw error }
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .onDisappear { session = nil }
    }
}
