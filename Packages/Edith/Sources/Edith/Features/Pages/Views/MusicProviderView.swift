import AppKit
import EdithKit
import SwiftUI
import WebKit

struct MusicProviderContent: View {
    @State private var accounts = MusicAccounts.shared
    init(accounts: MusicAccounts? = nil) {
        _accounts = State(initialValue: accounts ?? .shared)
    }
    @State private var spotifyLink = ""
    @State private var profiles: [ChromeProfile] = []
    @State private var selectedProfile = ""
    @State private var showProfiles = false
    @State private var profileError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            if accounts.selected == .spotify { spotify } else { youtube }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .font(Font.edithText(.body))
        .buttonStyle(.edith(.secondary))
        .edithSheet(isPresented: $showProfiles) { profilePicker }
        .pageTask { accounts.activate() }
    }

    private var spotify: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            PageSectionHeader("Spotify") {
                HStack {
                    if accounts.spotify.connected {
                        Button("Disconnect") { Task { await accounts.spotify.disconnect() } }
                    } else if accounts.spotify.connecting {
                        SkeletonGroup { SkeletonBlock(width: 16, height: 16, corner: 4) }
                            .accessibilityLabel("Connecting Spotify")
                        Button("Cancel") { accounts.spotify.stop() }
                    } else {
                        if accounts.spotify.hasSavedAccount {
                            Button("Disconnect") { Task { await accounts.spotify.disconnect() } }
                                .disabled(accounts.spotify.disconnecting)
                        }
                        Button("Connect Spotify") { accounts.spotify.connect() }
                            .disabled(accounts.spotify.disconnecting)
                    }
                }
            }
            if accounts.spotify.connected {
                Text("Connected as \(accounts.spotify.account)")
                    .presenterBlur(.music).foregroundStyle(.secondary)
                Text(
                    "Play a Spotify link here, or choose Edith in Spotify Connect to listen on this Mac."
                )
                .foregroundStyle(.secondary)
                HStack {
                    TextField("Spotify track, album, or playlist link", text: $spotifyLink)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { accounts.spotify.play(spotifyLink) }
                    Button("Play") { accounts.spotify.play(spotifyLink) }
                        .disabled(MusicProvider.spotifyURI(spotifyLink) == nil)
                }
                MusicStreamingControls(accounts: accounts)
                Button("Browse Spotify") { NSWorkspace.shared.open(MusicProvider.spotify.homeURL!) }
            } else {
                Text(
                    accounts.spotify.connecting
                        ? "Finish signing in in your browser. You can cancel here at any time."
                        : "Connect your Premium account to stream directly in Edith. Sign-in opens in your browser and your reusable credential stays in Keychain."
                )
                .foregroundStyle(.secondary)
            }
            if let error = accounts.spotify.error { errorMessage(error) }
        }
    }

    private var youtube: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            PageSectionHeader("YouTube Music") {
                HStack {
                    if accounts.youtubeConnecting {
                        SkeletonGroup { SkeletonBlock(width: 16, height: 16, corner: 4) }
                            .accessibilityLabel("Connecting YouTube Music")
                    }
                    Button(
                        accounts.youtubeConnected ? "Reconnect" : "Connect YouTube Music",
                        action: chooseProfile
                    )
                    .disabled(accounts.youtubeConnecting)
                    if accounts.youtubeConnected {
                        Button("Reload") {
                            accounts.youtubeError = nil; accounts.youtubeView?.reload()
                        }
                        Button("Disconnect") { Task { await accounts.disconnectYoutube() } }
                            .disabled(accounts.youtubeConnecting)
                    }
                }
            }
            if let error = accounts.youtubeError { errorMessage(error) }
            if let error = profileError { errorMessage(error) }
            if accounts.youtubeConnected, let view = accounts.youtubeView {
                MusicYoutubeWebView(view: view)
                    .frame(minHeight: UIScale.pt(360), maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(12)))
                    .presenterCover(.music)
            } else {
                Text(
                    "Sign in to YouTube Music in Chrome, then connect that profile. Edith imports only YouTube cookies into a separate player session. Your library, search, and playback stay inside this page."
                )
                .foregroundStyle(.secondary)
                Button("Sign in in Chrome") { openYoutubeInChrome() }
            }
        }
    }

    private func errorMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(Font.edithText(.callout)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseProfile() {
        profileError = nil
        Task {
            do {
                profiles = try await Task.detached { try MusicBrowserConnection.profiles() }.value
                selectedProfile = profiles.first?.id ?? ""
                if profiles.isEmpty {
                    profileError =
                        "Open Chrome and sign in to YouTube Music in a profile, then try again."
                } else {
                    showProfiles = true
                }
            } catch { profileError = error.localizedDescription }
        }
    }

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            Text("Connect YouTube Music").font(Font.edithText(.title2).weight(.semibold))
            Text(
                "Choose the Chrome profile signed in to your music account. macOS may ask you to allow access to Chrome Safe Storage in Keychain."
            )
            .foregroundStyle(.secondary)
            Picker("Chrome profile", selection: $selectedProfile) {
                ForEach(profiles) { profile in Text(profile.name).tag(profile.id) }
            }
            HStack {
                Button("Sign in in Chrome") { openYoutubeInChrome() }
                Spacer()
                Button("Cancel") { showProfiles = false }
                Button("Connect") {
                    guard let profile = profiles.first(where: { $0.id == selectedProfile }) else {
                        return
                    }
                    showProfiles = false
                    Task { await accounts.connectYoutube(profile) }
                }
                .disabled(selectedProfile.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(Font.edithText(.body))
        .buttonStyle(.edith(.secondary))
        .padding(UIScale.pt(24)).frame(width: UIScale.pt(480))
    }

    private func openYoutubeInChrome() {
        guard
            let chrome = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.google.Chrome")
        else {
            profileError = "Install Google Chrome to connect a YouTube Music account."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        if !selectedProfile.isEmpty {
            configuration.arguments = ["--profile-directory=\(selectedProfile)"]
        }
        NSWorkspace.shared.open(
            [MusicProvider.youtubeMusic.homeURL!], withApplicationAt: chrome,
            configuration: configuration)
    }
}

private struct MusicYoutubeWebView: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct MusicStreamingControls: View {
    @Environment(\.compactLayout) private var compact
    @State private var accounts = MusicAccounts.shared
    init(accounts: MusicAccounts? = nil) {
        _accounts = State(initialValue: accounts ?? .shared)
    }

    var body: some View {
        Group {
            if compact {
                VStack(spacing: UIScale.pt(8)) {
                    HStack(spacing: UIScale.pt(14)) {
                        trackSummary
                        transport
                    }
                    HStack(spacing: UIScale.pt(14)) {
                        positionSlider
                        volumeSlider
                    }
                }
            } else {
                HStack(spacing: UIScale.pt(14)) {
                    trackSummary
                    transport
                    positionSlider.frame(width: UIScale.pt(160))
                    volumeSlider
                }
            }
        }
        .font(Font.edithText(.body))
        .disabled(!accounts.spotify.connected)
    }

    private var trackSummary: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            Text(accounts.spotify.title.isEmpty ? "Nothing playing" : accounts.spotify.title)
                .font(Font.edithText(.headline)).lineLimit(1).presenterBlur(.music)
            Text(accounts.spotify.playing ? "Playing from Spotify" : "Spotify")
                .font(Font.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transport: some View {
        HStack(spacing: UIScale.pt(14)) {
            control("backward.fill", label: "Previous track", action: "previous")
            control(
                accounts.spotify.playing ? "pause.fill" : "play.fill", label: "Play or pause",
                action: "toggle")
            control("forward.fill", label: "Next track", action: "next")
        }
    }

    private var positionSlider: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Slider(
                value: Binding(
                    get: {
                        accounts.spotify.duration > 0
                            ? accounts.spotify.elapsed / accounts.spotify.duration : 0
                    },
                    set: {
                        accounts.spotify.seek(
                            by: $0 * accounts.spotify.duration - accounts.spotify.elapsed)
                    }),
                in: 0...1
            )
            .disabled(accounts.spotify.duration <= 0)
            .accessibilityLabel("Spotify playback position")
        }
    }

    private var volumeSlider: some View {
        Slider(
            value: Binding(
                get: { accounts.spotify.volume }, set: { accounts.spotify.setVolume($0) }),
            in: 0...1
        )
        .frame(width: UIScale.pt(90)).accessibilityLabel("Spotify volume")
    }

    private func control(_ symbol: String, label: String, action: String) -> some View {
        Button {
            accounts.spotify.send(["action": action])
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.edith(.toolbar))
        .accessibilityLabel(label).help(label)
    }
}
