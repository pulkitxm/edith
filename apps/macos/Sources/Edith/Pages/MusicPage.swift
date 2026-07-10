import AppKit
import EdithKit
import SwiftUI

@MainActor
final class WindowVisibility: ObservableObject {
    static let shared = WindowVisibility()

    @Published private(set) var visible = true
    private var observers: [NSObjectProtocol] = []

    private init() {
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func refresh() {
        let showing =
            !NSApp.isHidden
            && NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        if showing != visible { visible = showing }
    }
}

@MainActor
final class MusicRemote: ObservableObject {
    static let shared = MusicRemote()

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var currentFile: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var volume = 0.7
    @Published private(set) var looping = false
    @Published private(set) var duration: TimeInterval = 0

    private var elapsedBase: TimeInterval = 0
    private var elapsedTimestamp: TimeInterval = 0
    private var stateObserver: NSObjectProtocol?

    var current: Track? {
        currentFile.flatMap { file in tracks.first { $0.url.lastPathComponent == file } }
    }

    var elapsed: TimeInterval {
        let raw =
            isPlaying
            ? elapsedBase + (Date().timeIntervalSince1970 - elapsedTimestamp) : elapsedBase
        return duration > 0 ? min(max(raw, 0), duration) : max(raw, 0)
    }

    var progress: Double { duration > 0 ? min(elapsed / duration, 1) : 0 }

    private var folderObserver: NSObjectProtocol?

    func start() {
        rescan()
        guard stateObserver == nil else { return }
        stateObserver = IPC.observe(
            IPC.Name.musicState,
            info: { [weak self] info in
                MainActor.assumeIsolated { self?.apply(info) }
            })
        IPC.post(IPC.Name.requestMusicState)
        folderObserver = NotificationCenter.default.addObserver(
            forName: .musicFolderChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
    }

    func rescan() {
        tracks = TrackMeta.scanMusicFolder()
    }

    func apply(_ info: [AnyHashable: Any]) {
        let file = info["track"] as? String ?? ""
        currentFile = file.isEmpty ? nil : file
        isPlaying = info["isPlaying"] as? Bool ?? false
        duration = info["duration"] as? Double ?? 0
        looping = info["looping"] as? Bool ?? false
        if let value = info["volume"] as? Double { volume = value }
        elapsedBase = info["elapsed"] as? Double ?? 0
        elapsedTimestamp = info["at"] as? Double ?? Date().timeIntervalSince1970
    }

    private func send(_ action: String, _ extra: [String: Any] = [:]) {
        var info: [String: Any] = ["action": action]
        info.merge(extra) { a, _ in a }
        IPC.post(IPC.Name.musicCommand, userInfo: info)
    }

    func toggle(_ track: Track) { send("toggle", ["track": track.url.lastPathComponent]) }
    func playPause() { send("playPause") }
    func next() { send("next") }
    func previous() { send("previous") }
    func seek(to fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        if duration > 0 {
            elapsedBase = clamped * duration
            elapsedTimestamp = Date().timeIntervalSince1970
            objectWillChange.send()
        }
        send("seek", ["value": clamped])
    }
    func setVolume(_ value: Double) {
        volume = value
        send("volume", ["value": value])
    }
    func toggleLoop() { send("loop", ["value": !looping]) }

    func nudgeSeek(_ seconds: TimeInterval) {
        guard duration > 0 else { return }
        let target = min(max(elapsed + seconds, 0), duration)
        seek(to: target / duration)
    }

    func nudgeVolume(_ delta: Double) {
        setVolume(min(max(volume + delta, 0), 1))
    }
}

struct MusicPage: View {
    @ObservedObject private var remote = MusicRemote.shared
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var enabled = true
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store) private var presenterBlurMusic =
        true
    @StateObject private var presenterState = PresenterState.shared
    @Environment(\.colorScheme) private var scheme
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var showDownloader = false

    private var dark: Bool { scheme == .dark }
    private var theme: Color { themeColor(themeName) }
    private var blurMusic: Bool { presenterState.active && presenterBlurMusic }

    private var filteredTracks: [Track] {
        guard !search.isEmpty else { return remote.tracks }
        return remote.tracks.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)
            if !enabled {
                disabledBanner
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            trackList
        }
        .background(DashSkin.paper(dark).ignoresSafeArea(edges: .vertical))
        .navigationTitle("Music")
        .onAppear { remote.start() }
        .sheet(isPresented: $showDownloader) {
            DownloadSheet()
        }
        .onExitCommand {
            searchFocused = false
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("Music")
                    .font(DashSkin.serif(34))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer()
                Button {
                    try? FileManager.default.createDirectory(
                        at: Repo.musicDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Repo.musicDir)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(HoverButtonStyle())
                .help("Open music folder in Finder")
                Button {
                    remote.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(HoverButtonStyle())
                .help("Rescan music folder")
                Button {
                    showDownloader = true
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(HoverButtonStyle())
                .help("Download YouTube audio")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search tracks", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9).strokeBorder(DashSkin.line(dark), lineWidth: 1))
        }
    }

    private var disabledBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .foregroundStyle(.orange)
            Text("The music player is turned off - playback controls won't respond.")
                .font(.system(size: 12))
            Spacer()
            Toggle("Enable", isOn: $enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var trackList: some View {
        if remote.tracks.isEmpty {
            VStack(spacing: 8) {
                Text("No playable files in your music folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(Repo.musicDir.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredTracks) { track in
                        MusicPageRow(
                            track: track,
                            isCurrent: remote.currentFile == track.url.lastPathComponent,
                            isPlaying: remote.isPlaying, theme: theme, blur: blurMusic
                        ) {
                            remote.toggle(track)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
    }

}

struct SeekBar: View {
    @ObservedObject private var remote = MusicRemote.shared
    @ObservedObject private var visibility = WindowVisibility.shared
    let theme: Color
    var height: CGFloat = 5
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let knob = max(11, height + 7)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                if remote.isPlaying, visibility.visible, dragFraction == nil {
                    TimelineView(.periodic(from: MusicTick.epoch, by: 0.5)) { _ in
                        fill(geo.size.width, knob)
                    }
                } else {
                    fill(geo.size.width, knob)
                }
            }
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragFraction = min(max($0.location.x / geo.size.width, 0), 1) }
                    .onEnded { value in
                        remote.seek(to: min(max(value.location.x / geo.size.width, 0), 1))
                        dragFraction = nil
                    }
            )
        }
        .frame(height: height)
        .pointerCursor()
    }

    private func fill(_ width: CGFloat, _ knob: CGFloat) -> some View {
        let fraction = dragFraction ?? remote.progress
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(theme.opacity(0.85))
                .frame(width: width)
                .mask(alignment: .leading) {
                    Rectangle()
                        .scaleEffect(
                            x: width > 0 ? max(height, width * fraction) / width : 0,
                            anchor: .leading)
                }
            Circle()
                .fill(theme)
                .frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .offset(x: min(max(width * fraction - knob / 2, 0), width - knob))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MusicPageRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let theme: Color
    let blur: Bool
    let action: () -> Void
    @State private var duration: String?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PageArtworkThumb(track: track, size: 34)
                Text(track.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? theme : .primary)
                    .presenterBlur(blur)
                Spacer()
                if isCurrent {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme)
                }
                if let duration {
                    Text(duration)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isCurrent
                ? Color.primary.opacity(0.08) : hovering ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .onHover { hovering = $0 }
        .pointerCursor()
        .task {
            duration = await TrackMeta.durationLabel(for: track)
        }
    }
}

struct MusicFooter: View {
    @ObservedObject private var remote = MusicRemote.shared
    @ObservedObject private var visibility = WindowVisibility.shared
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var mainWindowSection =
        MainDestination.home.rawValue
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store) private var presenterBlurMusic =
        true
    @StateObject private var presenterState = PresenterState.shared
    @Environment(\.colorScheme) private var scheme

    private var theme: Color { themeColor(themeName) }
    private var blur: Bool { presenterState.active && presenterBlurMusic }

    var body: some View {
        Group {
            if let track = remote.current {
                playing(track)
            } else {
                idle
            }
        }
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    private func playing(_ track: Track) -> some View {
        HStack(spacing: 14) {
            trackInfo(track)
                .frame(maxWidth: .infinity, alignment: .leading)
            transport
            scrubber
                .frame(maxWidth: 420)
            rightControls
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 22)
    }

    private func trackInfo(_ track: Track) -> some View {
        HStack(spacing: 11) {
            PageArtworkThumb(track: track, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .presenterBlur(blur)
                Text(remote.isPlaying ? "Now playing" : "Paused")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
            }
            PlaybackWave(
                playing: remote.isPlaying && visibility.visible, color: theme.opacity(0.9),
                maxHeight: 13)
        }
        .contentShape(Rectangle())
        .onTapGesture { mainWindowSection = MainDestination.music.rawValue }
        .pointerCursor()
        .help("Open Music")
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Button {
                remote.previous()
            } label: {
                Image(systemName: "backward.fill").font(.system(size: 13)).foregroundStyle(theme)
            }
            .buttonStyle(HoverButtonStyle())
            .help("Previous track")
            Button {
                remote.playPause()
            } label: {
                ZStack {
                    Circle().fill(theme).frame(width: 36, height: 36)
                    Image(systemName: remote.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Play or pause")
            Button {
                remote.next()
            } label: {
                Image(systemName: "forward.fill").font(.system(size: 13)).foregroundStyle(theme)
            }
            .buttonStyle(HoverButtonStyle())
            .help("Next track")
        }
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            timeTicker {
                Text(TrackMeta.timeLabel(remote.elapsed))
                    .frame(width: 42, alignment: .trailing)
            }
            SeekBar(theme: theme, height: 4)
            timeTicker {
                Text("-" + TrackMeta.timeLabel(max(remote.duration - remote.elapsed, 0)))
                    .frame(width: 46, alignment: .leading)
            }
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func timeTicker<Content: View>(@ViewBuilder _ content: @escaping () -> Content)
        -> some View
    {
        if remote.isPlaying, visibility.visible {
            TimelineView(.periodic(from: MusicTick.epoch, by: 1)) { _ in content() }
        } else {
            content()
        }
    }

    private var rightControls: some View {
        HStack(spacing: 10) {
            Button {
                remote.toggleLoop()
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 13))
                    .foregroundStyle(remote.looping ? theme : .secondary)
            }
            .buttonStyle(HoverButtonStyle())
            .help(remote.looping ? "Looping current song" : "Shuffle next")
            Image(systemName: "speaker.wave.1")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { remote.volume }, set: { remote.setVolume($0) }),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(theme)
            .frame(width: 88)
            .pointerCursor()
        }
    }

    private var idle: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Nothing playing")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                mainWindowSection = MainDestination.music.rawValue
            } label: {
                Text("Browse music")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme)
            }
            .buttonStyle(HoverButtonStyle())
        }
        .padding(.horizontal, 22)
    }
}

private struct PageArtworkThumb: View {
    let track: Track
    var size: CGFloat = 36
    @State private var artwork: NSImage?

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(hue: track.hue, saturation: 0.55, brightness: 0.45),
                            Color(hue: track.hue, saturation: 0.6, brightness: 0.22),
                        ],
                        startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.36))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .task(id: track.id) { artwork = await TrackMeta.artwork(for: track) }
    }
}
