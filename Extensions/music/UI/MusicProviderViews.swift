import AppKit
import EdithExtensionUI
import EdithExtensionSupport
import SwiftUI

struct EmbeddedMusicProviderContent: View {
    @State private var accounts = EmbeddedMusicAccounts.shared
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    init(accounts: EmbeddedMusicAccounts? = nil) {
        _accounts = State(initialValue: accounts ?? .shared)
    }

    @State private var profiles: [EmbeddedChromeProfile] = []
    @State private var selectedProfile = ""
    @State private var showProfiles = false
    @State private var profileError: String?

    var body: some View {
        Group {
            if accounts.selected == .spotify, accounts.spotify.connected {
                EmbeddedMusicSpotifyWorkspace(accounts: accounts)
            } else if accounts.selected == .youtubeMusic, accounts.youtubeConnected {
                youtubePlayer()
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

    private func youtubePlayer() -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            PageSectionHeader("YouTube Music") {
                HStack(spacing: UIScale.pt(12)) {
                    PageToolbarButton(
                        action: {
                            accounts.reloadYoutube()
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
            EmbeddedMusicYoutubeWebView()
                .frame(minHeight: UIScale.pt(360), maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(12)))
                .presenterCover(EmbeddedMusicPrivacyState.shared.hides(.music))
        }
        .pageGutter(compact)
        .padding(.bottom, UIScale.pt(16))
    }

    @ViewBuilder private var youtubeErrors: some View {
        if let error = accounts.youtubeError { errorNotice(error) }
        if let error = profileError { errorNotice(error) }
    }

    private func connectionCard<Actions: View>(
        provider: EmbeddedMusicProvider, title: String, detail: String,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        PageCard {
            let layout =
                compact
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(18)))
                : AnyLayout(HStackLayout(alignment: .center, spacing: UIScale.pt(28)))
            layout {
                EmbeddedMusicSourceEmblem(provider: provider, size: compact ? 64 : 120)
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
                profiles = try await EmbeddedMusicRemote.shared.profiles()
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
        EmbeddedMusicRemote.shared.send(.openChrome, target: selectedProfile)
    }
}

struct EmbeddedMusicYoutubeWebView: View {
    @State private var frame: NSImage?
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let frame {
                    Image(nsImage: frame).resizable().scaledToFit()
                } else {
                    LoadingIndicator()
                }
            }
            .pageRefresh(interval: { .seconds(1) }) {
                frame = await EmbeddedMusicRemote.shared.youtubeFrame(
                    width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
}

private struct EmbeddedMusicSourceEmblem: View {
    let provider: EmbeddedMusicProvider
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

struct EmbeddedMusicStreamingArtwork: View {
    let url: URL?
    var size = 40.0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        EmbeddedMusicEngineImage(url: url) { image in
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
        .presenterCover(EmbeddedMusicPrivacyState.shared.hides(.music))
        .accessibilityHidden(true)
    }
}
