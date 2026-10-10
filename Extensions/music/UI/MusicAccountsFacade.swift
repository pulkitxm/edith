import AppKit
import EdithExtensionSupport
import Foundation
import Observation
import SwiftUI
import EdithExtensionUI

@MainActor @Observable final class EmbeddedMusicAccounts {
    static let shared = EmbeddedMusicAccounts()
    private(set) var selected = EmbeddedMusicProvider.local
    let spotify = EmbeddedMusicSpotifySession()
    private(set) var youtubeConnected = false
    private(set) var youtubeConnecting = false
    var youtubeError: String?
    var playerReady: Bool {
        selected == .local || (selected == .spotify ? spotify.connected : youtubeConnected)
    }
    var playerTitle: String? {
        if selected == .local { return EmbeddedMusicRemote.shared.current?.title }
        if selected == .spotify { return spotify.title.isEmpty ? nil : spotify.title }
        return youtubeConnected ? "YouTube Music" : nil
    }
    var isPlaying: Bool {
        selected == .local ? EmbeddedMusicRemote.shared.isPlaying : spotify.playing
    }
    var progress: Double {
        selected == .local
            ? EmbeddedMusicRemote.shared.progress
            : EmbeddedMusicBarProgress.fraction(
                elapsed: spotify.elapsed, duration: spotify.duration)
    }
    func reset() {
        selected = .local; youtubeConnected = false; youtubeConnecting = false; youtubeError = nil
        spotify.state = .init(
            connected: false, connecting: false, account: "", title: "", uri: "", artist: "",
            album: "", playing: false, elapsed: 0, duration: 0, volume: 0.7)
        spotify.library.reset()
    }
    func select(_ provider: EmbeddedMusicProvider) {
        EmbeddedMusicRemote.shared.send(.selectProvider, target: provider.rawValue)
    }
    func connectYoutube(_ profile: EmbeddedChromeProfile) async {
        EmbeddedMusicRemote.shared.send(.connectYoutube, target: profile.id)
    }
    func disconnectYoutube() async { EmbeddedMusicRemote.shared.send(.disconnectYoutube) }
    func reloadYoutube() { EmbeddedMusicRemote.shared.send(.reloadYoutube) }
    func activate() { EmbeddedMusicRemote.shared.start() }
    func apply(_ state: EmbeddedMusicUIState) {
        selected = EmbeddedMusicProvider(rawValue: state.selected) ?? .local
        youtubeConnected = state.youtubeConnected
        youtubeConnecting = state.youtubeConnecting; youtubeError = state.youtubeError
        spotify.state = state.spotify

    }
}

@MainActor @Observable final class EmbeddedMusicSpotifySession {
    var state = EmbeddedMusicUIStreaming(
        connected: false, connecting: false, account: "", title: "", uri: "", artist: "", album: "",
        playing: false, elapsed: 0, duration: 0, volume: 0.7)
    let library = EmbeddedMusicSpotifyLibrary()
    var connected: Bool { state.connected }
    var connecting: Bool { state.connecting }
    var account: String { state.account }
    var title: String { state.title }
    var uri: String { state.uri }
    var artist: String { state.artist }
    var artworkURL: URL? { state.artworkURL }
    var playing: Bool { state.playing }
    var duration: Double { state.duration }
    var elapsed: Double { state.elapsed }
    var volume: Double { state.volume }
    var error: String? { state.error }
    var disconnecting: Bool { state.disconnecting }
    var hasSavedAccount: Bool { state.hasSavedAccount }
    func connect() { EmbeddedMusicRemote.shared.send(.connectSpotify) }
    func stop() { EmbeddedMusicRemote.shared.send(.cancelSpotify) }
    func disconnect() async { EmbeddedMusicRemote.shared.send(.disconnectSpotify) }
    init() { library.configure { [weak self] in self?.send($0) } }
    func send(_ command: [String: Any]) {
        guard let action = command["action"] as? String else { return }
        if action == "toggle" {
            EmbeddedMusicRemote.shared.streaming("toggle")
        } else {
            EmbeddedMusicRemote.shared.spotify(command)
        }
    }
    func seek(by seconds: Double) {
        send([
            "action": "seek", "milliseconds": Int(max(0, min(duration, elapsed + seconds)) * 1000),
        ])
    }
    func setVolume(_ value: Double) {
        send(["action": "volume", "value": EmbeddedUnitInterval.clamp(value)])
    }
}

struct EmbeddedMusicEngineImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { content(Image(nsImage: image)) } else { placeholder() }
        }.pageTask(id: url) {
            image = nil
            guard let url else { return }
            if let data = try? await EmbeddedMusicRemote.shared.streamingArtwork(url),
                !Task.isCancelled
            {
                image = NSImage(data: data)
            }
        }
    }
}

struct EmbeddedMusicEmbeddedPage: View {
    var body: some View {
        EmbeddedMusicPage().overlay { EmbeddedMusicDetailOverlay() }
            .pageTask { EmbeddedMusicRemote.shared.start() }
            .pageRefresh(interval: { .seconds(1) }) { EmbeddedMusicRemote.shared.rescan() }
    }
}

struct EmbeddedChromeProfile: Identifiable, Sendable {
    var id: String
    var name: String
}

struct EmbeddedMusicSceneLoad<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .pageTask { EmbeddedMusicRemote.shared.rescan() }
            .pageRefresh(interval: { .seconds(1) }) { EmbeddedMusicRemote.shared.rescan() }
    }
}
