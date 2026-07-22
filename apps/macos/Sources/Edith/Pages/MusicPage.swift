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
    @Published private(set) var restorePending = SharedDefaults.store.integer(
        forKey: "restorePending.music")

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
    private var folderIPCObserver: NSObjectProtocol?

    func start() {
        if stateObserver != nil {
            rescan()
            return
        }
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
        folderIPCObserver = IPC.observe(IPC.Name.musicFolderChanged) { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        rescan()
    }

    func stop() {
        if let stateObserver {
            IPC.stopObserving(stateObserver)
            self.stateObserver = nil
        }
        if let folderObserver {
            NotificationCenter.default.removeObserver(folderObserver)
            self.folderObserver = nil
        }
        if let folderIPCObserver {
            IPC.stopObserving(folderIPCObserver)
            self.folderIPCObserver = nil
        }
        tracks = []
        currentFile = nil
        isPlaying = false
        duration = 0
    }

    func rescan() {
        tracks = TrackMeta.scanMusicFolder()
        restorePending = SharedDefaults.store.integer(forKey: "restorePending.music")
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

    func delete(_ track: Track) {
        try? FileManager.default.trashItem(at: track.url, resultingItemURL: nil)
        rescan()
        broadcastFolderChanged()
    }

    func rename(_ track: Track, to name: String) {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !base.isEmpty else { return }
        let ext = track.url.pathExtension
        let destination = track.url.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        guard destination != track.url,
            !FileManager.default.fileExists(atPath: destination.path),
            (try? FileManager.default.moveItem(at: track.url, to: destination)) != nil
        else { return }
        rescan()
        broadcastFolderChanged()
    }

    private func broadcastFolderChanged() {
        NotificationCenter.default.post(name: .musicFolderChanged, object: nil)
        IPC.post(IPC.Name.musicFolderChanged)
    }

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
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var tabMusicEnabled = false
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store) private var presenterBlurMusic =
        true
    @AppStorage(
        Repo.musicFolderStaleKey, store: SharedDefaults.store)
    private var musicFolderStale = false
    @StateObject private var presenterState = PresenterState.shared
    @Environment(\.colorScheme) private var scheme
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var showDownloader = false
    @State private var detailTarget: Track?
    @State private var detailBeginRename = false
    @State private var deleteTarget: Track?

    private var dark: Bool { scheme == .dark }
    private var theme: Color { themeColor(themeName) }
    private var blurMusic: Bool { presenterState.active && presenterBlurMusic }

    private var filteredTracks: [Track] {
        guard !search.isEmpty else { return remote.tracks }
        return remote.tracks.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            pageHeader
                .padding(.horizontal, UIScale.pt(24))
                .padding(.top, UIScale.pt(18))
                .padding(.bottom, UIScale.pt(12))
            if tabMusicEnabled, remote.restorePending > 0 {
                Text("Restoring your music from iCloud, \(remote.restorePending) remaining")
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, UIScale.pt(24))
                    .padding(.bottom, UIScale.pt(8))
            }
            trackList
        }
        .background(DashSkin.paper(dark).ignoresSafeArea(edges: .vertical))
        .navigationTitle("Music")
        .sheet(isPresented: $showDownloader) {
            DownloadSheet()
        }
        .sheet(item: $detailTarget) { track in
            MusicDetailSheet(
                track: track,
                isCurrent: remote.currentFile == track.url.lastPathComponent,
                isPlaying: remote.isPlaying,
                theme: theme,
                beginRename: detailBeginRename,
                onRename: { remote.rename(track, to: $0) },
                onDelete: {
                    detailTarget = nil
                    deleteTarget = track
                }
            )
        }
        .alert(
            "Move to Trash?", isPresented: deleteAlertBinding,
            presenting: deleteTarget
        ) { track in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Move to Trash", role: .destructive) {
                remote.delete(track)
                deleteTarget = nil
            }
        } message: { track in
            Text("\"\(track.title)\" will be moved to the Trash.")
        }
        .onExitCommand {
            searchFocused = false
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private func openDetails(_ track: Track, renaming: Bool) {
        detailBeginRename = renaming
        detailTarget = track
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
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
            if musicFolderStale {
                HStack(spacing: UIScale.pt(5)) {
                    Text("A previous external music folder was skipped.")
                    Button("Choose it again", action: chooseMusicFolder)
                        .buttonStyle(.link)
                }
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(.secondary)
            }
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
                TextField("Search tracks", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: UIScale.pt(13)))
                    .focused($searchFocused)
            }
            .padding(.horizontal, UIScale.pt(10))
            .padding(.vertical, UIScale.pt(7))
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(9)).strokeBorder(
                    DashSkin.line(dark), lineWidth: UIScale.pt(1)))
        }
    }

    @ViewBuilder private var trackList: some View {
        if remote.tracks.isEmpty {
            VStack(spacing: UIScale.pt(8)) {
                Text("No playable files in your music folder")
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(.secondary)
                Text(Repo.musicDir.path)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: UIScale.pt(2)) {
                    ForEach(filteredTracks) { track in
                        MusicPageRow(
                            track: track,
                            isCurrent: remote.currentFile == track.url.lastPathComponent,
                            isPlaying: remote.isPlaying, theme: theme, blur: blurMusic,
                            onOpenDetails: { openDetails(track, renaming: false) },
                            onRename: { openDetails(track, renaming: true) },
                            onDelete: { deleteTarget = track },
                            onToggle: { remote.toggle(track) }
                        )
                    }
                }
                .padding(.horizontal, UIScale.pt(24))
                .padding(.bottom, UIScale.pt(8))
            }
        }
    }

    private func chooseMusicFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose your music folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Repo.setMusicDirectory(url)
        remote.rescan()
        IPC.post(IPC.Name.musicFolderChanged)
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
                .shadow(color: .black.opacity(0.25), radius: UIScale.pt(2), y: 1)
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
    let onOpenDetails: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void
    @State private var duration: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Button(action: onOpenDetails) {
                PageArtworkThumb(track: track, size: 34)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Show details")
            Button(action: onToggle) {
                HStack(spacing: UIScale.pt(10)) {
                    Text(track.title)
                        .font(.system(size: UIScale.pt(13)))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? theme : .primary)
                        .presenterBlur(blur)
                    Spacer()
                    if isCurrent {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(theme)
                    }
                    if let duration {
                        Text(duration)
                            .font(.system(size: UIScale.pt(11)))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.vertical, UIScale.pt(6))
        .padding(.horizontal, UIScale.pt(8))
        .background(
            isCurrent
                ? Color.primary.opacity(0.08) : hovering ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(7))
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show Details", action: onOpenDetails)
            Button("Rename", action: onRename)
            Button("Move to Trash", role: .destructive, action: onDelete)
        }
        .task {
            duration = await TrackMeta.durationLabel(for: track)
        }
    }
}

private struct MusicDetailSheet: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let theme: Color
    let beginRename: Bool
    let onRename: (String) -> Void
    let onDelete: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var duration: String?

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: UIScale.pt(16)) {
            PageArtworkThumb(track: track, size: 168)
                .shadow(color: .black.opacity(0.25), radius: UIScale.pt(10), y: UIScale.pt(4))

            VStack(spacing: UIScale.pt(6)) {
                TextField("Track name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: UIScale.pt(15), weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DashSkin.ink(dark))
                    .focused($nameFocused)
                    .padding(.horizontal, UIScale.pt(12))
                    .padding(.vertical, UIScale.pt(8))
                    .background(
                        DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: UIScale.pt(8))
                            .strokeBorder(
                                nameFocused ? theme : DashSkin.line(dark), lineWidth: UIScale.pt(1))
                    )
                    .onSubmit(commitRename)

                HStack(spacing: UIScale.pt(10)) {
                    if let duration {
                        Label(duration, systemImage: "clock")
                    }
                    Label(track.url.pathExtension.uppercased(), systemImage: "waveform")
                    if isCurrent {
                        Label(
                            isPlaying ? "Playing" : "Paused",
                            systemImage: "dot.radiowaves.left.and.right"
                        )
                        .foregroundStyle(theme)
                    }
                }
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: UIScale.pt(10)) {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, UIScale.pt(8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .background(
                    Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                )
                .pointerCursor()

                Button(action: commitRename) {
                    Text(canRename ? "Rename" : "Done")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, UIScale.pt(8))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .background(theme, in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                .pointerCursor()
            }
            .font(.system(size: UIScale.pt(12), weight: .medium))
        }
        .padding(UIScale.pt(22))
        .frame(width: UIScale.pt(320))
        .background(DashSkin.paper(dark))
        .onAppear {
            name = track.url.deletingPathExtension().lastPathComponent
            if beginRename { nameFocused = true }
        }
        .task {
            duration = await TrackMeta.durationLabel(for: track)
        }
    }

    private var canRename: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != track.url.deletingPathExtension().lastPathComponent
    }

    private func commitRename() {
        if canRename { onRename(name) }
        dismiss()
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
        .frame(height: UIScale.pt(64))
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: UIScale.pt(1))
        }
    }

    private func playing(_ track: Track) -> some View {
        HStack(spacing: UIScale.pt(14)) {
            trackInfo(track)
                .frame(maxWidth: .infinity, alignment: .leading)
            transport
            scrubber
                .frame(maxWidth: UIScale.pt(420))
            rightControls
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, UIScale.pt(22))
    }

    private func trackInfo(_ track: Track) -> some View {
        HStack(spacing: UIScale.pt(11)) {
            PageArtworkThumb(track: track, size: 44)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(track.title)
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .lineLimit(1)
                    .presenterBlur(blur)
                Text(remote.isPlaying ? "Now playing" : "Paused")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(.secondary)
                    .frame(width: UIScale.pt(78), alignment: .leading)
            }
            PlaybackWave(
                playing: remote.isPlaying && visibility.visible, color: theme.opacity(0.9),
                maxHeight: UIScale.pt(13))
        }
        .contentShape(Rectangle())
        .onTapGesture { mainWindowSection = MainDestination.music.rawValue }
        .pointerCursor()
        .help("Open Music")
    }

    private var transport: some View {
        HStack(spacing: UIScale.pt(8)) {
            Button {
                remote.previous()
            } label: {
                Image(systemName: "backward.fill").font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(theme)
            }
            .buttonStyle(HoverButtonStyle())
            .help("Previous track")
            Button {
                remote.playPause()
            } label: {
                ZStack {
                    Circle().fill(theme).frame(width: UIScale.pt(36), height: UIScale.pt(36))
                    Image(systemName: remote.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: UIScale.pt(14), weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Play or pause")
            Button {
                remote.next()
            } label: {
                Image(systemName: "forward.fill").font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(theme)
            }
            .buttonStyle(HoverButtonStyle())
            .help("Next track")
        }
    }

    private var scrubber: some View {
        HStack(spacing: UIScale.pt(10)) {
            timeTicker {
                Text(TrackMeta.timeLabel(remote.elapsed))
                    .frame(width: UIScale.pt(42), alignment: .trailing)
            }
            SeekBar(theme: theme, height: UIScale.pt(4))
            timeTicker {
                Text("-" + TrackMeta.timeLabel(max(remote.duration - remote.elapsed, 0)))
                    .frame(width: UIScale.pt(46), alignment: .leading)
            }
        }
        .font(.system(size: UIScale.pt(10.5)))
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
        HStack(spacing: UIScale.pt(10)) {
            Button {
                remote.toggleLoop()
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(remote.looping ? theme : .secondary)
            }
            .buttonStyle(HoverButtonStyle())
            .help(remote.looping ? "Looping current song" : "Shuffle next")
            Image(systemName: "speaker.wave.1")
                .font(.system(size: UIScale.pt(10)))
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { remote.volume }, set: { remote.setVolume($0) }),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(theme)
            .frame(width: UIScale.pt(88))
            .pointerCursor()
        }
    }

    private var idle: some View {
        HStack(spacing: UIScale.pt(12)) {
            Image(systemName: "music.note")
                .font(.system(size: UIScale.pt(14)))
                .foregroundStyle(.secondary)
            Text("Nothing playing")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                mainWindowSection = MainDestination.music.rawValue
            } label: {
                Text("Browse music")
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                    .foregroundStyle(theme)
            }
            .buttonStyle(HoverButtonStyle())
        }
        .padding(.horizontal, UIScale.pt(22))
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
