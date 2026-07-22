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
    @Published private(set) var folderPath = ""
    @Published private(set) var folders: [MusicFolder] = []
    @Published private(set) var folderTracks: [Track] = []
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
        currentFile.flatMap { file in tracks.first { $0.relativePath == file } }
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
        if !folderPath.isEmpty,
            !FileManager.default.fileExists(atPath: TrackMeta.directory(for: folderPath).path)
        {
            folderPath = ""
        }
        refreshEntries()
        restorePending = SharedDefaults.store.integer(forKey: "restorePending.music")
    }

    private func refreshEntries() {
        let entries = TrackMeta.entries(in: folderPath)
        folders = entries.folders
        folderTracks = entries.tracks
    }

    func open(_ folder: MusicFolder) { navigate(to: folder.relativePath) }

    func navigate(to path: String) {
        folderPath = path
        refreshEntries()
    }

    func playFolder(_ folder: MusicFolder) { playAll(under: folder.relativePath) }

    func playCurrentFolder() { playAll(under: folderPath) }

    private func playAll(under relativePath: String) {
        guard !TrackMeta.tracks(under: relativePath).isEmpty else { return }
        send("playSource", ["sourceKind": "folder", "sourcePath": relativePath])
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

    func toggle(_ track: Track) {
        send("toggle", ["track": track.relativePath])
    }
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
        let base = sanitizedName(name)
        guard !base.isEmpty else { return }
        let ext = track.url.pathExtension
        let destination = track.url.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        moveFile(from: track.url, to: destination)
    }

    private func sanitizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    @discardableResult
    private func moveFile(from source: URL, to destination: URL) -> Bool {
        guard destination != source,
            !FileManager.default.fileExists(atPath: destination.path),
            (try? FileManager.default.moveItem(at: source, to: destination)) != nil
        else { return false }
        send(
            "renamed",
            [
                "from": TrackMeta.relativePath(of: source),
                "to": TrackMeta.relativePath(of: destination),
            ])
        rescan()
        broadcastFolderChanged()
        return true
    }

    func createFolder(named name: String) {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !base.isEmpty else { return }
        let dir = TrackMeta.directory(for: folderPath).appendingPathComponent(base)
        guard !FileManager.default.fileExists(atPath: dir.path),
            (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true))
                != nil
        else { return }
        refreshEntries()
        broadcastFolderChanged()
    }

    func move(_ track: Track, toFolderPath folderRelativePath: String) {
        let destination = TrackMeta.directory(for: folderRelativePath)
            .appendingPathComponent(track.url.lastPathComponent)
        moveFile(from: track.url, to: destination)
    }

    func move(relativePaths: [String], toFolderPath folderRelativePath: String) {
        for path in relativePaths {
            move(
                Track(url: Repo.musicDir.appendingPathComponent(path)),
                toFolderPath: folderRelativePath)
        }
    }

    func renameFolder(_ folder: MusicFolder, to name: String) {
        let base = sanitizedName(name)
        guard !base.isEmpty, base != folder.name else { return }
        let destination = folder.url.deletingLastPathComponent().appendingPathComponent(base)
        guard destination != folder.url,
            !FileManager.default.fileExists(atPath: destination.path),
            (try? FileManager.default.moveItem(at: folder.url, to: destination)) != nil
        else { return }
        let newPath = TrackMeta.relativePath(of: destination)
        if let playing = currentFile,
            playing == folder.relativePath || playing.hasPrefix(folder.relativePath + "/")
        {
            send(
                "renamed",
                ["from": playing, "to": newPath + playing.dropFirst(folder.relativePath.count)])
        }
        repointFolderPath(from: folder.relativePath, to: newPath)
        rescan()
        broadcastFolderChanged()
    }

    func deleteFolder(_ folder: MusicFolder) {
        guard (try? FileManager.default.trashItem(at: folder.url, resultingItemURL: nil)) != nil
        else { return }
        repointFolderPath(from: folder.relativePath, to: nil)
        rescan()
        broadcastFolderChanged()
    }

    private func repointFolderPath(from old: String, to new: String?) {
        guard folderPath == old || folderPath.hasPrefix(old + "/") else { return }
        if let new {
            folderPath = new + folderPath.dropFirst(old.count)
        } else {
            folderPath = (old as NSString).deletingLastPathComponent
        }
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
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameFolderTarget: MusicFolder?
    @State private var folderRenameText = ""
    @State private var deleteFolderTarget: MusicFolder?

    private var dark: Bool { scheme == .dark }
    private var theme: Color { themeColor(themeName) }
    private var blurMusic: Bool { presenterState.active && presenterBlurMusic }

    private var filteredTracks: [Track] {
        guard !search.isEmpty else { return remote.folderTracks }
        return remote.folderTracks.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private var filteredFolders: [MusicFolder] {
        guard !search.isEmpty else { return remote.folders }
        return remote.folders.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var moveTargets: [MoveTarget] {
        var targets: [MoveTarget] = []
        if !remote.folderPath.isEmpty {
            let parent = (remote.folderPath as NSString).deletingLastPathComponent
            let name = parent.isEmpty ? "Home" : (parent as NSString).lastPathComponent
            targets.append(MoveTarget(name: "\(name) (up)", path: parent))
        }
        targets += remote.folders.map { MoveTarget(name: $0.name, path: $0.relativePath) }
        return targets
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            pageHeader
                .padding(.horizontal, UIScale.pt(24))
                .padding(.top, UIScale.pt(18))
                .padding(.bottom, UIScale.pt(12))
            breadcrumbBar
                .padding(.horizontal, UIScale.pt(24))
                .padding(.bottom, UIScale.pt(10))
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
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                remote.createFolder(named: newFolderName)
                newFolderName = ""
            }
        } message: {
            Text(
                "Creates a folder inside \(remote.folderPath.isEmpty ? "your music library" : remote.folderPath)."
            )
        }
        .alert("Rename folder", isPresented: renameFolderBinding) {
            TextField("Folder name", text: $folderRenameText)
            Button("Cancel", role: .cancel) { renameFolderTarget = nil }
            Button("Rename") {
                if let folder = renameFolderTarget {
                    remote.renameFolder(folder, to: folderRenameText)
                }
                renameFolderTarget = nil
            }
        }
        .alert(
            "Move folder to Trash?", isPresented: deleteFolderBinding,
            presenting: deleteFolderTarget
        ) { folder in
            Button("Cancel", role: .cancel) { deleteFolderTarget = nil }
            Button("Move to Trash", role: .destructive) {
                remote.deleteFolder(folder)
                deleteFolderTarget = nil
            }
        } message: { folder in
            Text(
                "\"\(folder.name)\" and its \(folder.trackCount) track\(folder.trackCount == 1 ? "" : "s") will be moved to the Trash."
            )
        }
        .sheet(item: $detailTarget) { track in
            MusicDetailSheet(
                track: track,
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

    private var renameFolderBinding: Binding<Bool> {
        Binding(get: { renameFolderTarget != nil }, set: { if !$0 { renameFolderTarget = nil } })
    }

    private var deleteFolderBinding: Binding<Bool> {
        Binding(get: { deleteFolderTarget != nil }, set: { if !$0 { deleteFolderTarget = nil } })
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
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(HoverButtonStyle())
                .help("New folder")
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

    private var crumbSegments: [(name: String, path: String)] {
        guard !remote.folderPath.isEmpty else { return [] }
        var cumulative = ""
        return remote.folderPath.split(separator: "/").map { part in
            cumulative = cumulative.isEmpty ? String(part) : cumulative + "/" + part
            return (String(part), cumulative)
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(4)) {
                crumb("Home", path: "", systemImage: "house.fill")
                chevronMenu(parentPath: "")
                ForEach(crumbSegments, id: \.path) { segment in
                    crumb(segment.name, path: segment.path, systemImage: nil)
                    chevronMenu(parentPath: segment.path)
                }
            }
            .padding(.vertical, UIScale.pt(2))
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: UIScale.pt(8))
            Button {
                remote.playCurrentFolder()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, UIScale.pt(14))
                    .padding(.vertical, UIScale.pt(7))
                    .liquidGlass(in: Capsule(), tint: theme, interactive: true, dark: dark)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Play everything in this folder")
        }
    }

    private func crumb(_ name: String, path: String, systemImage: String?) -> some View {
        CrumbButton(
            name: name, path: path, systemImage: systemImage, theme: theme,
            isCurrent: path == remote.folderPath,
            onTap: { remote.navigate(to: path) },
            onDrop: { remote.move(relativePaths: $0, toFolderPath: path) }
        )
    }

    @ViewBuilder
    private func chevronMenu(parentPath: String) -> some View {
        let folders = TrackMeta.entries(in: parentPath).folders
        if folders.isEmpty {
            Image(systemName: "chevron.right")
                .font(.system(size: UIScale.pt(9)))
                .foregroundStyle(.tertiary)
        } else {
            Menu {
                ForEach(folders) { folder in
                    Button(folder.name) { remote.navigate(to: folder.relativePath) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: UIScale.pt(9), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: UIScale.pt(16), height: UIScale.pt(16))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
            .help("Jump to a folder here")
        }
    }

    @ViewBuilder private var trackList: some View {
        if filteredFolders.isEmpty && filteredTracks.isEmpty {
            VStack(spacing: UIScale.pt(8)) {
                Text(
                    remote.folderPath.isEmpty
                        ? "No playable files in your music folder" : "This folder is empty"
                )
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(.secondary)
                Text(TrackMeta.directory(for: remote.folderPath).path)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: UIScale.pt(2)) {
                    ForEach(filteredFolders) { folder in
                        MusicFolderRow(
                            folder: folder, theme: theme,
                            onOpen: { remote.open(folder) },
                            onPlay: { remote.playFolder(folder) },
                            onDrop: {
                                remote.move(relativePaths: $0, toFolderPath: folder.relativePath)
                            },
                            onRename: {
                                folderRenameText = folder.name
                                renameFolderTarget = folder
                            },
                            onDelete: { deleteFolderTarget = folder }
                        )
                    }
                    ForEach(filteredTracks) { track in
                        MusicPageRow(
                            track: track,
                            isCurrent: remote.currentFile == track.relativePath,
                            isPlaying: remote.isPlaying, theme: theme, blur: blurMusic,
                            moveTargets: moveTargets,
                            onOpenDetails: { openDetails(track, renaming: false) },
                            onRename: { openDetails(track, renaming: true) },
                            onDelete: { deleteTarget = track },
                            onMove: { remote.move(track, toFolderPath: $0) },
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

private struct CrumbButton: View {
    let name: String
    let path: String
    let systemImage: String?
    let theme: Color
    let isCurrent: Bool
    let onTap: () -> Void
    let onDrop: ([String]) -> Void
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: UIScale.pt(3)) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: UIScale.pt(10)))
            }
            Text(name).lineLimit(1)
        }
        .font(.system(size: UIScale.pt(12), weight: isCurrent ? .semibold : .regular))
        .foregroundStyle(isCurrent ? AnyShapeStyle(theme) : AnyShapeStyle(.secondary))
        .padding(.horizontal, UIScale.pt(7))
        .padding(.vertical, UIScale.pt(4))
        .background(
            dropTargeted ? theme.opacity(0.2) : .clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(6))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .pointerCursor()
        .dropDestination(for: String.self) { paths, _ in
            guard !isCurrent else { return false }
            onDrop(paths)
            return !paths.isEmpty
        } isTargeted: {
            dropTargeted = $0 && !isCurrent
        }
    }
}

private struct MusicFolderRow: View {
    let folder: MusicFolder
    let theme: Color
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onDrop: ([String]) -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Button(action: onOpen) {
                HStack(spacing: UIScale.pt(10)) {
                    ZStack {
                        RoundedRectangle(cornerRadius: UIScale.pt(7))
                            .fill(theme.opacity(0.16))
                            .frame(width: UIScale.pt(34), height: UIScale.pt(34))
                        Image(systemName: "folder.fill")
                            .font(.system(size: UIScale.pt(14)))
                            .foregroundStyle(theme)
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                        Text(folder.name)
                            .font(.system(size: UIScale.pt(13), weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text("\(folder.trackCount) track\(folder.trackCount == 1 ? "" : "s")")
                            .font(.system(size: UIScale.pt(10.5)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: UIScale.pt(22)))
                    .foregroundStyle(theme)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Play this folder")
            .opacity(hovering || folder.trackCount == 0 ? 1 : 0.55)

            Image(systemName: "chevron.right")
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, UIScale.pt(6))
        .padding(.horizontal, UIScale.pt(8))
        .background(
            dropTargeted
                ? theme.opacity(0.16) : hovering ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(7))
                .strokeBorder(theme, lineWidth: dropTargeted ? UIScale.pt(1.5) : 0)
        )
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { paths, _ in
            onDrop(paths)
            return !paths.isEmpty
        } isTargeted: {
            dropTargeted = $0
        }
        .contextMenu {
            Button("Play", action: onPlay)
            Button("Open", action: onOpen)
            Button("Rename", action: onRename)
            Button("Move to Trash", role: .destructive, action: onDelete)
        }
    }
}

struct MoveTarget: Identifiable, Equatable {
    let name: String
    let path: String
    var id: String { path }
}

private struct MusicPageRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let theme: Color
    let blur: Bool
    let moveTargets: [MoveTarget]
    let onOpenDetails: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onMove: (String) -> Void
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
        .draggable(track.relativePath)
        .contextMenu {
            Button("Show Details", action: onOpenDetails)
            Button("Rename", action: onRename)
            if !moveTargets.isEmpty {
                Menu("Move to Folder") {
                    ForEach(moveTargets) { target in
                        Button(target.name) { onMove(target.path) }
                    }
                }
            }
            Button("Move to Trash", role: .destructive, action: onDelete)
        }
        .task {
            duration = await TrackMeta.durationLabel(for: track)
        }
    }
}

private struct MusicDetailSheet: View {
    let track: Track
    let theme: Color
    let beginRename: Bool
    let onRename: (String) -> Void
    let onDelete: () -> Void
    @ObservedObject private var remote = MusicRemote.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var duration: String?
    @State private var sizeText: String?
    @State private var addedText: String?
    @State private var sourceURL: URL?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private var dark: Bool { scheme == .dark }
    private var isCurrent: Bool { remote.currentFile == track.relativePath }
    private var isPlaying: Bool { isCurrent && remote.isPlaying }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            header
            content
        }
        .frame(width: UIScale.pt(400))
        .background(sheetBackground)
        .onAppear {
            name = track.url.deletingPathExtension().lastPathComponent
            sourceURL = YoutubeDownloader.shared.sourceURL(
                forFileNamed: track.url.lastPathComponent)
            if beginRename { nameFocused = true }
        }
        .task { await loadDetails() }
    }

    private var sheetBackground: some View {
        LinearGradient(
            colors: [
                Color(
                    hue: track.hue, saturation: dark ? 0.28 : 0.14, brightness: dark ? 0.2 : 0.99),
                DashSkin.paper(dark),
            ],
            startPoint: .top, endPoint: .center
        )
        .overlay(DashSkin.paper(dark).opacity(dark ? 0.35 : 0.15))
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: UIScale.pt(26), height: UIScale.pt(26))
                    .background(DashSkin.paper2(dark).opacity(0.6), in: Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, UIScale.pt(16))
        .padding(.top, UIScale.pt(14))
    }

    private var content: some View {
        VStack(spacing: UIScale.pt(20)) {
            artwork
                .padding(.top, UIScale.pt(2))
            titleField
            metadata
            if isCurrent {
                playerBlock
            }
            if let sourceURL {
                youtubeLink(sourceURL)
            }
            actions
                .padding(.top, UIScale.pt(2))
        }
        .padding(.horizontal, UIScale.pt(28))
        .padding(.bottom, UIScale.pt(28))
        .padding(.top, UIScale.pt(6))
    }

    private var artwork: some View {
        PageArtworkThumb(track: track, size: 196)
            .shadow(color: .black.opacity(0.3), radius: UIScale.pt(16), y: UIScale.pt(8))
            .overlay(alignment: .bottomTrailing) {
                Button {
                    remote.toggle(track)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: UIScale.pt(19), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: UIScale.pt(52), height: UIScale.pt(52))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Circle(), tint: theme, interactive: true, dark: dark)
                .shadow(color: .black.opacity(0.28), radius: UIScale.pt(8), y: UIScale.pt(3))
                .pointerCursor()
                .help(isPlaying ? "Pause" : "Play")
                .offset(x: UIScale.pt(10), y: UIScale.pt(10))
            }
    }

    private var titleField: some View {
        TextField("Track name", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: UIScale.pt(17), weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(DashSkin.ink(dark))
            .focused($nameFocused)
            .padding(.horizontal, UIScale.pt(14))
            .padding(.vertical, UIScale.pt(10))
            .background(
                DashSkin.paper2(dark).opacity(nameFocused ? 1 : 0),
                in: RoundedRectangle(cornerRadius: UIScale.pt(10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .strokeBorder(
                        nameFocused ? theme : .clear, lineWidth: UIScale.pt(1))
            )
            .onSubmit(commitRename)
    }

    private var metadata: some View {
        HStack(spacing: UIScale.pt(10)) {
            if let duration { chip(duration, "clock") }
            if duration != nil, sizeText != nil { separator }
            if let sizeText { chip(sizeText, "internaldrive") }
            if sizeText != nil, addedText != nil { separator }
            if let addedText { chip(addedText, "calendar") }
        }
        .font(.system(size: UIScale.pt(11.5)))
        .foregroundStyle(.secondary)
    }

    private var separator: some View {
        Circle()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: UIScale.pt(2.5), height: UIScale.pt(2.5))
    }

    private var playerBlock: some View {
        VStack(spacing: UIScale.pt(8)) {
            SeekBar(theme: theme, height: UIScale.pt(5))
            HStack {
                ticker { Text(TrackMeta.timeLabel(remote.elapsed)) }
                Spacer()
                Label(isPlaying ? "Now Playing" : "Paused", systemImage: "waveform")
                    .font(.system(size: UIScale.pt(10.5), weight: .medium))
                    .foregroundStyle(theme)
                Spacer()
                ticker {
                    Text("-" + TrackMeta.timeLabel(max(remote.duration - remote.elapsed, 0)))
                }
            }
            .font(.system(size: UIScale.pt(10.5)))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func ticker<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View
    {
        if isPlaying {
            TimelineView(.periodic(from: MusicTick.epoch, by: 1)) { _ in content() }
        } else {
            content()
        }
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }

    private func youtubeLink(_ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: "play.rectangle.fill")
                Text("Open original on YouTube")
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: UIScale.pt(9)))
            }
            .font(.system(size: UIScale.pt(11.5), weight: .medium))
            .foregroundStyle(theme)
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(8))
            .background(theme.opacity(0.1), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var actions: some View {
        HStack(spacing: UIScale.pt(10)) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, UIScale.pt(11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            .pointerCursor()

            if canRename {
                Button(action: commitRename) {
                    Label("Rename", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, UIScale.pt(11))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .background(theme, in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
                .pointerCursor()
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .font(.system(size: UIScale.pt(12.5), weight: .semibold))
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: canRename)
    }

    private var canRename: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != track.url.deletingPathExtension().lastPathComponent
    }

    private func commitRename() {
        if canRename { onRename(name) }
        dismiss()
    }

    private func loadDetails() async {
        let attrs = try? FileManager.default.attributesOfItem(atPath: track.url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value
        if let bytes {
            sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if let created = attrs?[.creationDate] as? Date {
            addedText = Self.dateFormatter.string(from: created)
        }
        if let seconds = await TrackMeta.duration(for: track), seconds > 0 {
            duration = TrackMeta.timeLabel(seconds)
        }
    }
}

@available(macOS 26, *)
private enum GlassStyle {
    static func make(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    @ViewBuilder
    func liquidGlass<S: InsettableShape>(
        in shape: S, tint: Color? = nil, interactive: Bool = false, dark: Bool = false
    ) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(GlassStyle.make(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background((tint ?? .clear).opacity(tint == nil ? 0 : 0.28), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(dark ? 0.16 : 0.4), lineWidth: 1))
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
    private var dark: Bool { scheme == .dark }

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
            glassButton("backward.fill", diameter: 34, iconSize: 12, tint: nil) {
                remote.previous()
            }
            .help("Previous track")
            glassButton(
                remote.isPlaying ? "pause.fill" : "play.fill",
                diameter: 42, iconSize: 15, iconColor: .white, tint: theme
            ) {
                remote.playPause()
            }
            .help("Play or pause")
            glassButton("forward.fill", diameter: 34, iconSize: 12, tint: nil) {
                remote.next()
            }
            .help("Next track")
        }
    }

    private func glassButton(
        _ symbol: String, diameter: CGFloat, iconSize: CGFloat, iconColor: Color? = nil,
        tint: Color?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(iconSize), weight: .semibold))
                .foregroundStyle(iconColor ?? theme)
                .frame(width: UIScale.pt(diameter), height: UIScale.pt(diameter))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .liquidGlass(in: Circle(), tint: tint, interactive: true, dark: dark)
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
            glassButton(
                "repeat", diameter: 34, iconSize: 12,
                iconColor: remote.looping ? .white : .secondary,
                tint: remote.looping ? theme : nil
            ) {
                remote.toggleLoop()
            }
            .help(remote.looping ? "Repeating this track" : "Play through the queue")
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: "speaker.wave.1")
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { remote.volume }, set: { remote.setVolume($0) }),
                    in: 0...1
                )
                .controlSize(.mini)
                .tint(theme)
                .frame(width: UIScale.pt(80))
                .pointerCursor()
            }
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(7))
            .liquidGlass(in: Capsule(), dark: dark)
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
