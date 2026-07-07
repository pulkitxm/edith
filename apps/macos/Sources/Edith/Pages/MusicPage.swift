import AppKit
import EdithKit
import SwiftUI

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

    func start() {
        rescan()
        guard stateObserver == nil else { return }
        stateObserver = IPC.observe(
            IPC.Name.musicState,
            info: { [weak self] info in
                MainActor.assumeIsolated { self?.apply(info) }
            })
        IPC.post(IPC.Name.requestMusicState)
    }

    func rescan() {
        tracks = TrackMeta.scanMusicFolder()
    }

    private func apply(_ info: [AnyHashable: Any]) {
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
    func seek(to fraction: Double) { send("seek", ["value": fraction]) }
    func setVolume(_ value: Double) {
        volume = value
        send("volume", ["value": value])
    }
    func toggleLoop() { send("loop", ["value": !looping]) }
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
            nowPlayingBar
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .background(DashSkin.paper(dark).ignoresSafeArea(edges: .vertical))
        .navigationTitle("Music")
        .onAppear { remote.start() }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Music")
                    .font(DashSkin.serif(34))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer()
                Button {
                    try? FileManager.default.createDirectory(
                        at: Repo.musicDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Repo.musicDir)
                } label: {
                    Label("Music folder", systemImage: "folder")
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
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search tracks", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
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

    private var nowPlayingBar: some View {
        VStack(spacing: 10) {
            if remote.current != nil {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in scrubberRow }
            }
            HStack(spacing: 12) {
                if let track = remote.current {
                    PageArtworkThumb(track: track, size: 40)
                }
                Text(remote.current?.title ?? "Not playing")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(remote.current == nil ? .secondary : .primary)
                    .presenterBlur(blurMusic && remote.current != nil)
                if remote.current != nil {
                    PlaybackWave(playing: remote.isPlaying, color: theme.opacity(0.9))
                }
                Spacer()
                Button {
                    remote.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .foregroundStyle(theme)
                }
                .buttonStyle(HoverButtonStyle())
                Button {
                    remote.playPause()
                } label: {
                    Image(systemName: remote.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(theme)
                }
                .buttonStyle(HoverButtonStyle())
                Button {
                    remote.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .foregroundStyle(theme)
                }
                .buttonStyle(HoverButtonStyle())
                Button {
                    remote.toggleLoop()
                } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 13))
                        .foregroundStyle(remote.looping ? theme : .secondary)
                }
                .buttonStyle(HoverButtonStyle())
                .help(remote.looping ? "Looping current song" : "Shuffle next")
                Slider(
                    value: Binding(
                        get: { remote.volume },
                        set: { remote.setVolume($0) }),
                    in: 0...1
                )
                .controlSize(.small)
                .tint(theme)
                .frame(width: 74)
                .pointerCursor()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
        }
        .padding(12)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(DashSkin.line(dark), lineWidth: 1)
        )
        .background {
            if let track = remote.current {
                PageAmbientGlow(track: track)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var scrubberRow: some View {
        HStack(spacing: 10) {
            Text(TrackMeta.timeLabel(remote.elapsed))
                .frame(width: 44, alignment: .leading)
            SeekBar(theme: theme)
            Text(TrackMeta.timeLabel(remote.duration))
                .frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

}

struct SeekBar: View {
    @ObservedObject private var remote = MusicRemote.shared
    let theme: Color
    var height: CGFloat = 5
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let fraction = dragFraction ?? remote.progress
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule()
                    .fill(theme.opacity(0.85))
                    .frame(width: max(height, geo.size.width * fraction))
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

struct PlaybackWave: View {
    let playing: Bool
    let color: Color
    var barCount = 5
    var maxHeight: CGFloat = 18

    private static let weights: [Double] = [0.55, 0.85, 1.0, 0.75, 0.6, 0.9, 0.5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: height(i, t))
                }
            }
            .frame(height: maxHeight, alignment: .center)
        }
    }

    private func height(_ i: Int, _ t: Double) -> CGFloat {
        guard playing else { return maxHeight * 0.15 }
        let phase = sin(t * (1.8 + Double(i) * 0.37) + Double(i) * 1.7)
        let level = 0.3 + 0.7 * abs(phase)
        return maxHeight * CGFloat(max(0.15, level * Self.weights[i % Self.weights.count]))
    }
}

struct SidebarMiniPlayer: View {
    @ObservedObject private var remote = MusicRemote.shared
    let width: Double
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var mainWindowSection =
        MainDestination.home.rawValue
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store) private var presenterBlurMusic =
        true
    @StateObject private var presenterState = PresenterState.shared

    private var theme: Color { themeColor(themeName) }

    var body: some View {
        if let track = remote.current {
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .presenterBlur(presenterState.active && presenterBlurMusic)
                    Spacer(minLength: 4)
                    PlaybackWave(
                        playing: remote.isPlaying, color: theme.opacity(0.9), maxHeight: 12)
                }
                .contentShape(Rectangle())
                .onTapGesture { mainWindowSection = MainDestination.music.rawValue }
                .pointerCursor()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 4) {
                        SeekBar(theme: theme, height: 3)
                        HStack {
                            Text(TrackMeta.timeLabel(remote.elapsed))
                            Spacer()
                            Text(TrackMeta.timeLabel(remote.duration))
                        }
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        remote.playPause()
                    } label: {
                        Image(systemName: remote.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(theme)
                    }
                    .buttonStyle(HoverButtonStyle())
                    Button {
                        remote.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme)
                    }
                    .buttonStyle(HoverButtonStyle())
                    Spacer(minLength: 4)
                    if width >= 210 {
                        Image(systemName: "speaker.wave.1")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { remote.volume },
                                set: { remote.setVolume($0) }),
                            in: 0...1
                        )
                        .controlSize(.mini)
                        .tint(theme)
                        .frame(maxWidth: 90)
                        .pointerCursor()
                    }
                }
            }
            .padding(9)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        }
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

private struct PageAmbientGlow: View {
    let track: Track
    @Environment(\.colorScheme) private var scheme
    @State private var artwork: NSImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    LinearGradient(
                        colors: [
                            Color(hue: track.hue, saturation: 0.5, brightness: 0.5),
                            Color(hue: track.hue, saturation: 0.65, brightness: 0.25),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .blur(radius: 50)
            .overlay((scheme == .dark ? Color.black : Color.white).opacity(0.45))
            .clipped()
        }
        .task(id: track.id) { artwork = await TrackMeta.artwork(for: track) }
        .allowsHitTesting(false)
    }
}
