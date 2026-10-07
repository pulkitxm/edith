import AppKit
import EdithKit
import SwiftUI
import WebKit

struct MusicProviderContent: View {
    @State private var accounts = MusicAccounts.shared
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    init(accounts: MusicAccounts? = nil) {
        _accounts = State(initialValue: accounts ?? .shared)
    }

    @State private var profiles: [ChromeProfile] = []
    @State private var selectedProfile = ""
    @State private var showProfiles = false
    @State private var profileError: String?

    var body: some View {
        Group {
            if accounts.selected == .spotify, accounts.spotify.connected {
                MusicSpotifyWorkspace(accounts: accounts)
            } else if accounts.selected == .youtubeMusic, accounts.youtubeConnected,
                let view = accounts.youtubeView
            {
                youtubePlayer(view)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                        if accounts.selected == .spotify { spotify } else { youtube }
                    }
                    .pageContent(compact, width: .readable)
                }
                .scrollIndicators(.hidden)
            }
        }
        .font(.edithText(.body))
        .edithSheet(isPresented: $showProfiles) { profilePicker }
        .pageTask { accounts.activate() }
    }

    private var spotify: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            PageSectionHeader("Spotify", subtitle: "Your music, inside Edith")
            if let error = accounts.spotify.error { errorNotice(error) }
            connectionCard(
                provider: .spotify, title: "Listen with Spotify",
                detail: "Browse your library, find new music, and play it here."
            ) {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    if accounts.spotify.connecting {
                        HStack(spacing: UIScale.pt(8)) {
                            LoadingIndicator()
                            Text("Finish signing in in your browser.")
                                .font(.edithText(.caption)).foregroundStyle(.secondary)
                        }
                        Button("Cancel sign-in") { accounts.spotify.stop() }
                            .buttonStyle(.edith(.secondary))
                    } else {
                        Button {
                            accounts.spotify.connect()
                        } label: {
                            Label("Connect Spotify", systemImage: "arrow.right")
                        }
                        .buttonStyle(.edith(.primary)).disabled(accounts.spotify.disconnecting)
                        if accounts.spotify.hasSavedAccount {
                            Button("Remove saved account") {
                                Task { await accounts.spotify.disconnect() }
                            }
                            .buttonStyle(.edith(.secondary)).disabled(
                                accounts.spotify.disconnecting)
                        }
                    }
                    Label("Spotify Premium required for playback", systemImage: "info.circle")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
            PageColumns {
                featureRow(
                    "books.vertical", title: "Your whole library",
                    detail: "Playlists, Liked Songs, albums, artists, and podcasts.")
                featureRow(
                    "magnifyingglass", title: "Find your next song",
                    detail: "Search the catalog and build your listening queue.")
            }
        }
    }

    private var youtube: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            PageSectionHeader("YouTube Music", subtitle: "Your library and mixes, in Edith")
            youtubeErrors
            connectionCard(
                provider: .youtubeMusic, title: "Listen with YouTube Music",
                detail: "Bring your YouTube Music library, search, and playback into Edith."
            ) {
                HStack(spacing: UIScale.pt(10)) {
                    Button(action: chooseProfile) {
                        Label("Connect YouTube Music", systemImage: "arrow.right")
                    }
                    .buttonStyle(.edith(.primary))
                    .disabled(accounts.youtubeConnecting)
                    if accounts.youtubeConnecting { LoadingIndicator() }
                }
            }
            PageCard(title: "Connect your account") {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    HStack(alignment: .top, spacing: UIScale.pt(12)) {
                        stepNumber(1)
                        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                            Text("Sign in to YouTube Music")
                                .font(.edithText(.headline))
                            Text("Use the Chrome profile with your music account.")
                                .font(.edithText(.caption)).foregroundStyle(.secondary)
                            Button("Sign in in Chrome", action: openYoutubeInChrome)
                                .buttonStyle(.edith(.secondary))
                        }
                    }
                    Divider().opacity(0.5)
                    HStack(alignment: .top, spacing: UIScale.pt(12)) {
                        stepNumber(2)
                        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                            Text("Connect that profile")
                                .font(.edithText(.headline))
                            Text(
                                "Your music opens here. Other websites and accounts stay in Chrome."
                            )
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func youtubePlayer(_ view: WKWebView) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            PageSectionHeader("YouTube Music") {
                HStack(spacing: UIScale.pt(12)) {
                    PageToolbarButton(
                        action: {
                            accounts.youtubeError = nil; view.reload()
                        },
                        systemImage: "arrow.clockwise", helperText: "Reload YouTube Music")
                    Menu {
                        Button("Reconnect", action: chooseProfile)
                        Button("Disconnect YouTube Music") {
                            Task { await accounts.disconnectYoutube() }
                        }
                    } label: {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(.edithText(.caption))
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(accounts.youtubeConnecting)
                }
            }
            youtubeErrors
            MusicYoutubeWebView(view: view)
                .frame(minHeight: UIScale.pt(360), maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(12)))
                .presenterCover(.music)
        }
        .pageGutter(compact)
        .padding(.bottom, UIScale.pt(16))
    }

    @ViewBuilder private var youtubeErrors: some View {
        if let error = accounts.youtubeError { errorNotice(error) }
        if let error = profileError { errorNotice(error) }
    }

    private func connectionCard<Actions: View>(
        provider: MusicProvider, title: String, detail: String,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        PageCard {
            let layout =
                compact
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(18)))
                : AnyLayout(HStackLayout(alignment: .center, spacing: UIScale.pt(28)))
            layout {
                MusicSourceEmblem(provider: provider, size: compact ? 64 : 120)
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    Text(title).font(.edithText(.title2)).fontWeight(.semibold)
                    Text(detail).font(.edithText(.body)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    actions()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(UIScale.pt(12))
        }
    }

    private func featureRow(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(12)) {
            Image(systemName: symbol)
                .font(.edithText(.title3))
                .foregroundStyle(DashSkin.accent(scheme == .dark))
                .frame(width: UIScale.pt(30), height: UIScale.pt(30))
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                Text(title).font(.edithText(.headline))
                Text(detail).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stepNumber(_ number: Int) -> some View {
        Text(number.formatted()).font(.edithText(.caption)).fontWeight(.semibold)
            .frame(width: UIScale.pt(26), height: UIScale.pt(26))
            .background(.primary.opacity(0.07), in: Circle())
    }

    private func errorNotice(_ message: String) -> some View {
        PageNotice(message, tone: .error)
    }

    private func chooseProfile() {
        profileError = nil
        Task {
            do {
                profiles = try await Task.detached { try MusicBrowserConnection.profiles() }.value
                selectedProfile = profiles.first?.id ?? ""
                if profiles.isEmpty {
                    profileError = "Open Chrome and sign in to YouTube Music, then try again."
                } else {
                    showProfiles = true
                }
            } catch { profileError = error.localizedDescription }
        }
    }

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            Label("Connect YouTube Music", systemImage: "play.circle")
                .font(.edithText(.title3)).fontWeight(.semibold)
            Text("Choose the Chrome profile where you signed in to YouTube Music.")
                .foregroundStyle(.secondary)
            Picker("Chrome profile", selection: $selectedProfile) {
                ForEach(profiles) { profile in Text(profile.name).tag(profile.id) }
            }
            HStack {
                Button("Sign in in Chrome", action: openYoutubeInChrome)
                    .buttonStyle(.edith(.secondary))
                Spacer()
                Button("Cancel") { showProfiles = false }
                    .buttonStyle(.edith(.secondary))
                Button("Connect") {
                    guard let profile = profiles.first(where: { $0.id == selectedProfile }) else {
                        return
                    }
                    showProfiles = false
                    Task { await accounts.connectYoutube(profile) }
                }
                .buttonStyle(.edith(.primary))
                .disabled(selectedProfile.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(.edithText(.body))
        .padding(UIScale.pt(24)).frame(width: PresentationMetrics.width(480))
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

struct MusicYoutubeWebView: View {
    let view: WKWebView

    var body: some View {
        MusicYoutubeWebViewHost(view: view).id(ObjectIdentifier(view))
    }
}

private struct MusicYoutubeWebViewHost: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct MusicSourceEmblem: View {
    let provider: MusicProvider
    let size: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let accent = DashSkin.accent(scheme == .dark)
        ZStack {
            Circle().fill(accent.opacity(0.08))
            Circle().strokeBorder(accent.opacity(0.12), lineWidth: UIScale.pt(1))
                .padding(UIScale.pt(size * 0.1))
            Image(systemName: provider.symbol)
                .font(.system(size: UIScale.pt(size * 0.38), weight: .light))
                .foregroundStyle(accent)
        }
        .frame(width: UIScale.pt(size), height: UIScale.pt(size))
        .accessibilityHidden(true)
    }
}

struct MusicStreamingArtwork: View {
    let url: URL?
    var size = 40.0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                LinearGradient(
                    colors: [
                        DashSkin.accent(scheme == .dark).opacity(0.3),
                        DashSkin.paper2(scheme == .dark),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().strokeBorder(.primary.opacity(0.08), lineWidth: UIScale.pt(1))
                    .padding(UIScale.pt(size * 0.14))
                Circle().fill(.primary.opacity(0.08))
                    .frame(width: UIScale.pt(size * 0.33), height: UIScale.pt(size * 0.33))
                Image(systemName: "music.note").font(.system(size: UIScale.pt(size * 0.25)))
                    .foregroundStyle(DashSkin.accent(scheme == .dark))
            }
        }
        .frame(width: UIScale.pt(size), height: UIScale.pt(size))
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(size > 60 ? 12 : 6)))
        .presenterCover(.music)
        .accessibilityHidden(true)
    }
}

struct MusicStreamingControls: View {
    @Environment(\.compactLayout) private var compact
    @State private var optionsPresented = false
    @State private var accounts = MusicAccounts.shared
    init(accounts: MusicAccounts? = nil) {
        _accounts = State(initialValue: accounts ?? .shared)
    }

    var body: some View {
        HStack(spacing: UIScale.pt(14)) {
            trackSummary
            if compact {
                transport
                Button {
                    optionsPresented = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: UIScale.pt(26), height: UIScale.pt(30))
                }
                .buttonStyle(.edith(.toolbar))
                .accessibilityLabel("Spotify playback options")
                .popover(isPresented: $optionsPresented) {
                    VStack(spacing: UIScale.pt(12)) {
                        positionSlider
                        playbackModes
                        volumeSlider
                    }
                    .padding(UIScale.pt(16))
                    .frame(width: PresentationMetrics.width(280))
                }
            } else {
                VStack(spacing: UIScale.pt(3)) {
                    HStack(spacing: UIScale.pt(12)) {
                        playbackModes; transport
                    }
                    positionSlider
                }.frame(width: UIScale.pt(280))
                Spacer(minLength: 0)
                Button {
                    accounts.spotify.library.showQueue()
                    accounts.spotify.library.navigate(to: .queue)
                    SharedDefaults.store.set(
                        MainDestination.music.rawValue,
                        forKey: AppStorageKeys.General.mainWindowSection)
                } label: {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(.edith(.toolbar)).accessibilityLabel("Open playback queue")
                volumeSlider
            }
        }
        .font(.edithText(.body))
        .disabled(!accounts.spotify.connected)
    }

    private var trackSummary: some View {
        HStack(spacing: UIScale.pt(10)) {
            MusicStreamingArtwork(url: accounts.spotify.artworkURL)
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(accounts.spotify.title.isEmpty ? "Nothing playing" : accounts.spotify.title)
                    .font(.edithText(.headline)).lineLimit(1).presenterBlur(.music)
                Text(accounts.spotify.artist.isEmpty ? "Spotify" : accounts.spotify.artist)
                    .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    .presenterBlur(.music)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playbackModes: some View {
        HStack(spacing: UIScale.pt(8)) {
            Button {
                accounts.spotify.library.setShuffle(!accounts.spotify.library.shuffle)
            } label: {
                Image(systemName: "shuffle").foregroundStyle(
                    accounts.spotify.library.shuffle ? Color.accentColor : .secondary)
            }.buttonStyle(.edith(.toolbar)).accessibilityLabel("Shuffle")
            Button {
                let modes = ["off", "context", "track"]
                let index = modes.firstIndex(of: accounts.spotify.library.repeatMode) ?? 0
                accounts.spotify.library.setRepeat(modes[(index + 1) % modes.count])
            } label: {
                Image(
                    systemName: accounts.spotify.library.repeatMode == "track"
                        ? "repeat.1" : "repeat"
                )
                .foregroundStyle(
                    accounts.spotify.library.repeatMode == "off" ? Color.secondary : .accentColor)
            }.buttonStyle(.edith(.toolbar)).accessibilityLabel(
                "Repeat: \(accounts.spotify.library.repeatMode)")
        }
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
            VStack(spacing: UIScale.pt(2)) {
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
                .frame(width: UIScale.pt(compact ? 248 : 280))
                .disabled(accounts.spotify.duration <= 0)
                .accessibilityLabel("Spotify playback position")
                HStack {
                    Text(TrackMeta.timeLabel(accounts.spotify.elapsed))
                    Spacer()
                    Text(TrackMeta.timeLabel(accounts.spotify.duration))
                }
                .font(.edithText(.caption2)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var volumeSlider: some View {
        HStack(spacing: UIScale.pt(6)) {
            Image(systemName: "speaker.wave.2")
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { accounts.spotify.volume }, set: { accounts.spotify.setVolume($0) }),
                in: 0...1
            )
            .frame(width: UIScale.pt(80)).accessibilityLabel("Spotify volume")
        }
    }

    private func control(_ symbol: String, label: String, action: String) -> some View {
        Button {
            accounts.spotify.send(["action": action])
        } label: {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(14)))
                .frame(width: UIScale.pt(28), height: UIScale.pt(30))
        }
        .buttonStyle(.edith(.toolbar))
        .accessibilityLabel(label).help(label)
    }
}
