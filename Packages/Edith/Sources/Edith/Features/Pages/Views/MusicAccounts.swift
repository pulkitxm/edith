import AppKit
import CryptoKit
import EdithCore
import EdithKit
import Observation
import WebKit

@MainActor
@Observable
final class MusicSpotifySession {
    private(set) var connected = false
    private(set) var connecting = false
    private(set) var disconnecting = false
    private(set) var account = ""
    private(set) var title = ""
    private(set) var playing = false
    private(set) var duration = 0.0
    private(set) var volume = 0.7
    var error: String?
    private var elapsedBase = 0.0
    private var updatedAt = Date()
    private var process: MusicPlaybackProcess?
    private var authorizationDeadline: Task<Void, Never>?
    private var buffer = Data()
    private(set) var generation = 0
    private let executable: URL?
    private let defaults: UserDefaults
    private let service: String

    var elapsed: Double {
        min(duration, max(0, elapsedBase + (playing ? Date().timeIntervalSince(updatedAt) : 0)))
    }

    init(
        executable: URL? = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("edith-music-player"),
        defaults: UserDefaults = SharedDefaults.store,
        service: String = AppBuildIdentity.keychainService("music")
    ) {
        self.executable = executable
        self.defaults = defaults
        self.service = service
    }

    func connect(authorize: Bool = true) {
        guard !connected, process == nil, !disconnecting else { return }
        guard authorize || defaults.bool(forKey: "musicSpotifyAccountSaved") else { return }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            error = MusicConnectionError.playerUnavailable.localizedDescription
            return
        }
        generation += 1
        let token = generation
        error = nil
        connecting = true
        do {
            process = try MusicPlaybackProcess(
                executable: executable,
                arguments: [service, "Edith"] + (authorize ? [] : ["--resume"]),
                receive: { [weak self] data in
                    Task { @MainActor in self?.receive(data, generation: token) }
                },
                onExit: { [weak self] in
                    Task { @MainActor in self?.terminated(generation: token) }
                })
            authorizationDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(600)) } catch { return }
                guard let self, self.generation == token, self.connecting else { return }
                self.error = "Spotify sign-in timed out. Connect again to retry."
                self.stop()
            }
        } catch {
            self.error = error.localizedDescription
            terminated(generation: token)
        }
    }

    func receive(_ data: Data, generation token: Int) {
        guard token == generation else { return }
        buffer.append(data)
        guard buffer.count <= 65_536 else {
            error = "The Spotify player sent an invalid response."
            stop()
            return
        }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            apply(event)
        }
    }

    private func apply(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "connected":
            authorizationDeadline?.cancel()
            authorizationDeadline = nil
            connected = true
            connecting = false
            account = event["account"] as? String ?? "Spotify account"
            defaults.set(true, forKey: "musicSpotifyAccountSaved")
            send(["action": "volume", "value": volume])
        case "track":
            title = event["title"] as? String ?? ""
            duration = max(0, event["duration"] as? Double ?? 0)
            elapsedBase = 0
            updatedAt = Date()
        case "state":
            playing = event["playing"] as? Bool ?? false
            elapsedBase = max(0, event["elapsed"] as? Double ?? 0)
            updatedAt = Date()
        case "position":
            elapsedBase = max(0, event["elapsed"] as? Double ?? 0)
            updatedAt = Date()
        case "volume": volume = min(1, max(0, event["value"] as? Double ?? volume))
        case "error":
            error = event["message"] as? String ?? "Spotify could not complete this request."
        default: break
        }
    }

    func play(_ link: String) {
        guard let uri = MusicProvider.spotifyURI(link) else {
            error = MusicConnectionError.invalidLink.localizedDescription
            return
        }
        error = nil
        send(["action": "play", "uri": uri])
    }

    func send(_ command: [String: Any]) {
        guard connected, let process,
            let data = try? JSONSerialization.data(withJSONObject: command)
        else { return }
        let token = generation
        process.send(data + Data([10])) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.error = "The Spotify player stopped responding. Reconnect to continue."
            }
        }
    }

    func seek(by seconds: Double) {
        guard seconds.isFinite else { return }
        let position = min(duration, max(0, elapsed + seconds))
        elapsedBase = position
        updatedAt = Date()
        send(["action": "seek", "milliseconds": Int(min(Double(UInt32.max), position * 1000))])
    }

    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = min(1, max(0, value))
        send(["action": "volume", "value": volume])
    }

    func stop() {
        generation += 1
        authorizationDeadline?.cancel()
        authorizationDeadline = nil
        process?.stop()
        process = nil
        buffer = Data()
        resetPlayback()
    }

    private func resetPlayback() {
        connected = false
        connecting = false
        account = ""
        title = ""
        playing = false
        duration = 0
        elapsedBase = 0
    }

    func terminated(generation token: Int) {
        guard token == generation else { return }
        if error == nil { error = "The Spotify connection ended. Reconnect to continue." }
        stop()
    }

    func disconnect() async {
        guard !disconnecting else { return }
        let previous = process
        stop()
        disconnecting = true
        defer { disconnecting = false }
        guard let executable else { return }
        await previous?.waitForExit()
        let result = try? await CLICommandRunner.runLocal(
            CLICommandRequest(
                executableURL: executable, arguments: [service, "Edith", "--forget"],
                environment: ProcessInfo.processInfo.environment, timeout: 10,
                maximumOutputBytes: 4096,
                discardsStandardError: true, terminatesProcessGroup: true), onLine: { _ in })
        let succeeded = result?.terminationStatus == 0
        if succeeded {
            defaults.removeObject(forKey: "musicSpotifyAccountSaved")
            error = nil
        } else {
            error =
                "The saved Spotify account could not be removed from Keychain. Try disconnecting again."
        }
    }
}

@MainActor
@Observable
final class MusicAccounts: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = MusicAccounts()
    private(set) var selected: MusicProvider
    let spotify: MusicSpotifySession
    private(set) var youtubeConnected: Bool
    private(set) var youtubeConnecting = false
    private(set) var youtubeView: WKWebView?
    var youtubeError: String?
    private let defaults: UserDefaults
    private var youtubeGeneration = 0
    private let pauseLocal: @MainActor () -> Void

    var playerTitle: String? {
        switch selected {
        case .local: MusicRemote.shared.current?.title
        case .spotify: spotify.title.isEmpty ? nil : spotify.title
        case .youtubeMusic: youtubeConnected ? "YouTube Music" : nil
        }
    }

    var isPlaying: Bool {
        switch selected {
        case .local: MusicRemote.shared.isPlaying
        case .spotify: spotify.playing
        case .youtubeMusic: false
        }
    }

    var progress: Double {
        switch selected {
        case .local: MusicRemote.shared.progress
        case .spotify:
            MusicBarProgress.fraction(elapsed: spotify.elapsed, duration: spotify.duration)
        case .youtubeMusic: 0
        }
    }

    init(
        defaults: UserDefaults = SharedDefaults.store, spotify: MusicSpotifySession? = nil,
        pauseLocal: @escaping @MainActor () -> Void = { MusicRemote.shared.pausePlayback() }
    ) {
        self.defaults = defaults
        self.spotify = spotify ?? MusicSpotifySession(defaults: defaults)
        self.pauseLocal = pauseLocal
        selected =
            MusicProvider(rawValue: defaults.string(forKey: "musicSelectedProvider") ?? "")
            ?? .local
        youtubeConnected = defaults.bool(forKey: "musicYoutubeAccountSaved")
        super.init()
    }

    func select(_ provider: MusicProvider) {
        guard selected != provider else { return }
        switch selected {
        case .local: pauseLocal()
        case .spotify: spotify.send(["action": "pause"])
        case .youtubeMusic:
            youtubeView?.evaluateJavaScript(
                "document.querySelector('video')?.pause()", completionHandler: nil)
        }
        selected = provider
        defaults.set(provider.rawValue, forKey: "musicSelectedProvider")
        activate()
    }

    func activate() {
        if selected == .spotify { spotify.connect(authorize: false) }
        if selected == .youtubeMusic, youtubeConnected { loadYoutube() }
    }

    func shutdown() {
        spotify.stop()
        youtubeView?.evaluateJavaScript(
            "document.querySelector('video')?.pause()", completionHandler: nil)
    }

    private var youtubeStore: WKWebsiteDataStore {
        let digest = Array(
            SHA256.hash(data: Data((AppBuildIdentity.application + ".music.youtube").utf8)))
        let uuid = UUID(
            uuid: (
                digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6],
                digest[7], digest[8], digest[9], digest[10], digest[11], digest[12], digest[13],
                digest[14], digest[15]
            ))
        return WKWebsiteDataStore(forIdentifier: uuid)
    }

    func connectYoutube(_ profile: ChromeProfile) async {
        guard !youtubeConnecting else { return }
        youtubeGeneration += 1
        let token = youtubeGeneration
        youtubeConnecting = true
        youtubeError = nil
        defer { if token == youtubeGeneration { youtubeConnecting = false } }
        do {
            try await MusicBrowserConnection.importSession(profile: profile, into: youtubeStore)
            guard token == youtubeGeneration else { return }
            youtubeConnected = true
            defaults.set(true, forKey: "musicYoutubeAccountSaved")
            youtubeView?.stopLoading()
            youtubeView?.evaluateJavaScript(
                "document.querySelector('video')?.pause()", completionHandler: nil)
            youtubeView = nil
            loadYoutube()
        } catch { if token == youtubeGeneration { youtubeError = error.localizedDescription } }
    }

    func disconnectYoutube() async {
        guard !youtubeConnecting else { return }
        youtubeGeneration += 1
        youtubeConnecting = true
        defer { youtubeConnecting = false }
        youtubeView?.stopLoading()
        youtubeView?.evaluateJavaScript(
            "document.querySelector('video')?.pause()", completionHandler: nil)
        youtubeView = nil
        await youtubeStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        youtubeConnected = false
        defaults.removeObject(forKey: "musicYoutubeAccountSaved")
        youtubeError = nil
    }

    func loadYoutube() {
        guard youtubeView == nil, youtubeConnected else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = youtubeStore
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        youtubeView = view
        view.load(URLRequest(url: MusicProvider.youtubeMusic.homeURL!))
    }

    static func isYoutubePage(_ url: URL) -> Bool {
        url.scheme == "https"
            && ["music.youtube.com", "www.youtube.com", "consent.youtube.com"].contains(
                url.host ?? "")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        guard navigationAction.targetFrame?.isMainFrame != false,
            let url = navigationAction.request.url
        else { return .allow }
        if Self.isYoutubePage(url) { return .allow }
        if url.scheme == "https" {
            NSWorkspace.shared.open(url)
            if url.host == "accounts.google.com" {
                youtubeError = "Sign in in Chrome, then reconnect your YouTube Music session."
            }
        }
        return .cancel
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if (error as NSError).code != NSURLErrorCancelled {
            youtubeError = "YouTube Music could not load. Check your connection and reload."
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        youtubeError = "The YouTube Music player stopped. Reload to continue."
    }
}
