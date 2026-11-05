import AppKit
import Combine
import EdithExtensionUI
import EdithExtensionSupport
import Observation
import SwiftUI

private struct EmbeddedMusicListQuery: Equatable {
    var search: String
    var showingFavourites: Bool
    var favourites: [EmbeddedTrack]
    var folders: [EmbeddedMusicFolder]
    var folderTracks: [EmbeddedTrack]
    var searchTracks: [EmbeddedTrack]
    var searchFolders: [EmbeddedMusicFolder]
}

private struct EmbeddedMusicListSelection {
    var folders: [EmbeddedMusicFolder] = []
    var tracks: [EmbeddedTrack] = []
    var contentKey: [String] = []

    init() {}

    init(query: EmbeddedMusicListQuery) {
        folders = Self.matchingFolders(query)
        tracks = Self.matchingTracks(query)
        contentKey = folders.map(\.relativePath) + tracks.map(\.relativePath)
    }

    private static func matchingFolders(_ query: EmbeddedMusicListQuery) -> [EmbeddedMusicFolder] {
        guard !query.showingFavourites else { return [] }
        guard !query.search.isEmpty else { return query.folders }
        return query.searchFolders.filter {
            $0.name.localizedCaseInsensitiveContains(query.search)
        }
    }

    private static func matchingTracks(_ query: EmbeddedMusicListQuery) -> [EmbeddedTrack] {
        guard !query.search.isEmpty else {
            return query.showingFavourites ? query.favourites : query.folderTracks
        }
        let source = query.showingFavourites ? query.favourites : query.searchTracks
        return source.filter { $0.title.localizedCaseInsensitiveContains(query.search) }
    }
}

struct EmbeddedMusicPage: View {
    @State private var accounts = EmbeddedMusicAccounts.shared
    init(accounts: EmbeddedMusicAccounts? = nil) {
        _accounts = State(initialValue: accounts ?? .shared)
    }
    @State private var remote = EmbeddedMusicRemote.shared
    @AppStorage(
        AppStorageKeys.General.theme,
        store: SharedDefaults.store) private var themeName =
        "accent"
    @AppStorage(
        EmbeddedMusicStorage.musicFolderStaleKey, store: SharedDefaults.store)
    private var musicFolderStale = false
    @AppStorage(AppStorageKeys.Music.gridView, store: SharedDefaults.store) private var gridView =
        false
    private var presenterState = EmbeddedMusicPrivacyState.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var gridWidth: CGFloat = 0
    @State private var showDownloader = false
    @State private var deleteTarget: EmbeddedTrack?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameFolderTarget: EmbeddedMusicFolder?
    @State private var folderRenameText = ""
    @State private var deleteFolderTarget: EmbeddedMusicFolder?
    @State private var selection = EmbeddedMusicListSelection()

    private var dark: Bool { scheme == .dark }
    private var musicPlaceBinding: Binding<String> {
        Binding(
            get: { remote.showingFavourites ? "favourites" : remote.folderPath },
            set: { value in
                if value == "favourites" {
                    remote.openFavourites()
                } else {
                    remote.navigate(to: value)
                }
            })
    }

    private func musicPlaceIsValid(_ value: String) -> Bool {
        if value.isEmpty || value == "favourites" { return true }
        return !value.hasPrefix("/") && !value.contains("..")
    }

    private var theme: Color { themeColor(themeName) }
    private var blurMusic: Bool { presenterState.active }

    private var listQuery: EmbeddedMusicListQuery {
        EmbeddedMusicListQuery(
            search: search, showingFavourites: remote.showingFavourites,
            favourites: remote.favourites, folders: remote.folders,
            folderTracks: remote.folderTracks, searchTracks: remote.searchTracks,
            searchFolders: remote.searchFolders)
    }

    private var filteredTracks: [EmbeddedTrack] { selection.tracks }

    private var filteredFolders: [EmbeddedMusicFolder] { selection.folders }

    private var contentKey: [String] { selection.contentKey }

    private func location(of relativePath: String) -> String? {
        guard !search.isEmpty, !remote.showingFavourites else { return nil }
        let parent = (relativePath as NSString).deletingLastPathComponent
        guard parent != remote.folderPath else { return nil }
        let scoped =
            remote.folderPath.isEmpty
            ? parent : String(parent.dropFirst(remote.folderPath.count + 1))
        return scoped.replacingOccurrences(of: "/", with: " / ")
    }

    private var moveTargets: [EmbeddedMoveTarget] {
        var targets: [EmbeddedMoveTarget] = []
        if !remote.folderPath.isEmpty {
            let parent = (remote.folderPath as NSString).deletingLastPathComponent
            let name = parent.isEmpty ? "Home" : (parent as NSString).lastPathComponent
            targets.append(EmbeddedMoveTarget(name: "\(name) (up)", path: parent))
        }
        targets += remote.folders.map { EmbeddedMoveTarget(name: $0.name, path: $0.relativePath) }
        return targets
    }

    var body: some View {
        PageWorkspace {
            if accounts.selected != .spotify || !accounts.spotify.connected { pageHeader }
        } content: {
            if accounts.selected == .local {
                trackList
            } else {
                EmbeddedMusicProviderContent(accounts: accounts)
            }
        }
        .navigationRoute("place", selection: musicPlaceBinding, isValid: musicPlaceIsValid)
        .navigationTitle("Music")
        .edithSheet(isPresented: $showDownloader) { EmbeddedDownloadSheet() }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                remote.createFolder(named: newFolderName)
                newFolderName = ""
            }
        } message: {
            let folder =
                remote.folderPath.isEmpty ? "your music library" : remote.folderPath
            Text(
                EmbeddedMusicPrivacyState.shared.hides(.music)
                    ? "Creates a folder inside your music library."
                    : "Creates a folder inside \(folder)."
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
                EmbeddedMusicPrivacyState.shared.hides(.music)
                    ? "This folder and everything inside it will be moved to the Trash."
                    : "\"\(folder.name)\" and everything inside it will be moved to the Trash."
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
            Text(
                EmbeddedMusicPrivacyState.shared.hides(.music)
                    ? "This track will be moved to the Trash."
                    : "\"\(track.title)\" will be moved to the Trash."
            )
        }
        .alert(
            "Music library error",
            isPresented: Binding(
                get: { remote.libraryError != nil },
                set: { if !$0 { remote.dismissLibraryError() } })
        ) {
            Button("OK") { remote.dismissLibraryError() }
        } message: {
            Text(remote.libraryError ?? "The music library operation failed.")
        }
        .onChange(of: gridView) {
            EmbeddedMusicRemote.shared.send(.gridView, value: gridView ? 1 : 0)
        }
        .onChange(of: search) { remote.noteSearch(search) }
        .onChange(of: remote.folderPath) { if !search.isEmpty { remote.noteSearch(search) } }
        .onChange(of: listQuery, initial: true) { _, query in
            selection = EmbeddedMusicListSelection(query: query)
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

    private func openDetails(_ track: EmbeddedTrack, renaming: Bool) {
        EmbeddedMusicDetailPresenter.shared.show(track, renaming: renaming)
    }

    private var providerConnectVisible: Bool {
        switch accounts.selected {
        case .local: false
        case .spotify: !accounts.spotify.connected
        case .youtubeMusic: !accounts.youtubeConnected
        }
    }

    private var pageHeader: some View {
        PageHeader("Music") {
            if accounts.selected == .local {
                headerActions.padding(.trailing, -UIScale.pt(6))
            }
        } accessory: {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                EdithSegmentedPicker(
                    "Music source",
                    selection: Binding(get: { accounts.selected }, set: { accounts.select($0) }),
                    options: EmbeddedMusicProvider.allCases, label: { $0.title }
                )
                .frame(maxWidth: UIScale.pt(440))
                if accounts.selected == .local {
                    if musicFolderStale {
                        HStack(spacing: UIScale.pt(5)) {
                            Text("A previous external music folder was skipped.")
                            Button("Choose it again", action: chooseMusicFolder)
                                .buttonStyle(.link)
                        }
                        .font(.edithText(.subheadline))
                        .foregroundStyle(.secondary)
                    }
                    if !libraryIsEmpty {
                        searchField
                        breadcrumbBar
                    }
                    if remote.restorePending > 0 {
                        Text("Restoring your music from iCloud, \(remote.restorePending) remaining")
                            .settingsCaption()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .environment(
            \.pageColumnWidth,
            providerConnectVisible && !compact ? UIScale.pt(PageMetrics.readableWidth) : nil)
    }

    private var viewIsEmpty: Bool {
        let loaded =
            remote.showingFavourites
            ? remote.favouritesLoaded
            : (search.isEmpty ? remote.entriesLoaded : remote.searchLoaded)
        return loaded && filteredFolders.isEmpty && filteredTracks.isEmpty
    }

    private var libraryIsEmpty: Bool {
        viewIsEmpty && search.isEmpty && !remote.showingFavourites && remote.folderPath.isEmpty
    }

    private var headerActions: some View {
        HStack(spacing: UIScale.pt(4)) {
            Button {
                gridView.toggle()
            } label: {
                Image(systemName: gridView ? "list.bullet" : "square.grid.2x2")
            }
            .buttonStyle(.edith(.toolbar))
            .help(gridView ? "Show as list" : "Show as grid")
            .accessibilityLabel(gridView ? "Show as list" : "Show as grid")
            Button {
                if remote.showingFavourites {
                    remote.navigate(to: remote.folderPath)
                } else {
                    remote.openFavourites()
                }
            } label: {
                Image(systemName: remote.showingFavourites ? "heart.fill" : "heart")
                    .foregroundStyle(
                        remote.showingFavourites
                            ? AnyShapeStyle(theme) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.edith(.toolbar))
            .help(remote.showingFavourites ? "Back to your folders" : "Show favourites")
            .accessibilityLabel(
                remote.showingFavourites ? "Back to your folders" : "Show favourites")
            Button {
                newFolderName = ""
                showNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.edith(.toolbar))
            .help("New folder")
            .accessibilityLabel("New folder")
            Button {
                EmbeddedMusicRemote.shared.openLibrary()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.edith(.toolbar))
            .help("Open music folder in Finder")
            .accessibilityLabel("Open music folder in Finder")
            Button {
                remote.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.edith(.toolbar))
            .help("Rescan music folder")
            .accessibilityLabel("Rescan music folder")
            Button {
                showDownloader = true
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.edith(.toolbar))
            .help("Download YouTube audio")
            .accessibilityLabel("Download YouTube audio")
        }
    }

    private var searchField: some View {
        SearchField(placeholder: "Search tracks", text: $search, typeAhead: true)
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
            if remote.showingFavourites {
                Label("Favourites", systemImage: "heart.fill")
                    .font(.edithText(.callout).weight(.semibold))
                    .foregroundStyle(theme)
                    .padding(.vertical, UIScale.pt(6))
            } else {
                ScrollView(.horizontal) {
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
                }
                .scrollIndicators(.hidden)
                .padding(.leading, -UIScale.pt(7))
            }
            Spacer(minLength: UIScale.pt(8))
            Button {
                if remote.showingFavourites {
                    remote.playFavourites()
                } else {
                    remote.playCurrentFolder()
                }
            } label: {
                Label(
                    remote.showingFavourites ? "Play favourites" : "Play all",
                    systemImage: "play.fill")
            }
            .buttonStyle(.edith(.primary))
            .disabled(!remote.canPlayView)
            .opacity(viewIsEmpty ? 0 : 1)
            .accessibilityHidden(viewIsEmpty)
            .help(
                remote.showingFavourites
                    ? "Play your favourites" : "Play everything in this folder")
        }
    }

    private func crumb(_ name: String, path: String, systemImage: String?) -> some View {
        EmbeddedCrumbButton(
            name: name, path: path, systemImage: systemImage, theme: theme,
            isCurrent: path == remote.folderPath,
            onTap: { remote.navigate(to: path) },
            onDrop: { remote.move(relativePaths: $0, toFolderPath: path) }
        )
    }

    @ViewBuilder
    private func chevronMenu(parentPath: String) -> some View {
        if let folders = remote.subfolders(of: parentPath) {
            if folders.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: UIScale.pt(9)))
                    .foregroundStyle(.tertiary)
            } else {
                Menu {
                    ForEach(folders) { folder in
                        Button(
                            EmbeddedMusicPrivacyState.shared.hides(.music) ? "Folder" : folder.name
                        ) { remote.navigate(to: folder.relativePath) }
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
                .help("Jump to a folder here")
            }
        } else {
            SkeletonGroup { SkeletonBlock(width: 16, height: 16, corner: 4) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading folders")
        }
    }

    @ViewBuilder private var trackList: some View {
        if remote.showingFavourites
            ? !remote.favouritesLoaded
            : (search.isEmpty ? !remote.entriesLoaded : !remote.searchLoaded)
        {
            ScrollView {
                EmbeddedMusicLibrarySkeleton(grid: gridView)
                    .pageContent(compact)
            }
        } else if filteredFolders.isEmpty && filteredTracks.isEmpty {
            EmbeddedMusicLocalEmptyState(
                kind: .resolve(
                    search: search, showingFavourites: remote.showingFavourites,
                    folderPath: remote.folderPath),
                folderLocation: EmbeddedMusicPrivacyState.shared.hides(.music)
                    ? nil : EmbeddedTrackMeta.url(for: remote.folderPath).path,
                download: { showDownloader = true },
                openLibrary: { remote.openLibrary() },
                clearSearch: { search = "" },
                showFolders: { remote.navigate(to: remote.folderPath) },
                goUp: {
                    remote.navigate(to: (remote.folderPath as NSString).deletingLastPathComponent)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Group {
                    if gridView { gridContent } else { listContent }
                }
                .pageContent(compact)
                .animation(
                    Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: contentKey)
            }
        }
    }

    private var listContent: some View {
        LazyVStack(spacing: UIScale.pt(2)) {
            ForEach(filteredFolders) { folder in
                EmbeddedMusicFolderRow(
                    folder: folder, theme: theme, location: location(of: folder.relativePath),
                    onOpen: { remote.open(folder) },
                    onPlay: { remote.playFolder(folder) },
                    onDrop: {
                        remote.move(relativePaths: $0, toFolderPath: folder.relativePath)
                    },
                    onRename: { beginFolderRename(folder) },
                    onDelete: { deleteFolderTarget = folder }
                )
            }
            ForEach(filteredTracks) { track in
                EmbeddedMusicPageRow(
                    track: track, location: location(of: track.relativePath),
                    isCurrent: remote.currentFile == track.relativePath,
                    isPlaying: remote.isPlaying, theme: theme, blur: blurMusic,
                    moveTargets: moveTargets,
                    isFavourite: remote.favouritePaths.contains(track.relativePath),
                    onOpenDetails: { openDetails(track, renaming: false) },
                    onRename: { openDetails(track, renaming: true) },
                    onDelete: { deleteTarget = track },
                    onMove: { remote.move(track, toFolderPath: $0) },
                    onToggle: { remote.toggle(track) },
                    onToggleFavourite: { remote.toggleFavourite(track) },
                    onOpenFolder: { remote.reveal(track) }
                )
            }
        }
    }

    private var gridContent: some View {
        let layout = EmbeddedMusicTile.layout(
            count: filteredFolders.count + filteredTracks.count, available: gridWidth)
        return LazyVGrid(columns: layout.columns, spacing: UIScale.pt(16)) {
            ForEach(filteredFolders) { folder in
                EmbeddedMusicFolderTile(
                    folder: folder, theme: theme, location: location(of: folder.relativePath),
                    onOpen: { remote.open(folder) },
                    onPlay: { remote.playFolder(folder) },
                    onDrop: {
                        remote.move(relativePaths: $0, toFolderPath: folder.relativePath)
                    },
                    onRename: { beginFolderRename(folder) },
                    onDelete: { deleteFolderTarget = folder }
                )
            }
            ForEach(filteredTracks) { track in
                EmbeddedMusicTrackTile(
                    track: track, location: location(of: track.relativePath),
                    isCurrent: remote.currentFile == track.relativePath,
                    isPlaying: remote.isPlaying, theme: theme, blur: blurMusic,
                    moveTargets: moveTargets,
                    isFavourite: remote.favouritePaths.contains(track.relativePath),
                    onOpenDetails: { openDetails(track, renaming: false) },
                    onRename: { openDetails(track, renaming: true) },
                    onDelete: { deleteTarget = track },
                    onMove: { remote.move(track, toFolderPath: $0) },
                    onToggle: { remote.toggle(track) },
                    onToggleFavourite: { remote.toggleFavourite(track) },
                    onOpenFolder: { remote.reveal(track) }
                )
            }
        }
        .environment(\.musicTileArt, layout.art)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            gridWidth = $0
        }
    }

    private func beginFolderRename(_ folder: EmbeddedMusicFolder) {
        folderRenameText = folder.name
        renameFolderTarget = folder
    }

    private func chooseMusicFolder() { remote.chooseLibrary() }

}

struct EmbeddedSeekBar: View {
    @State private var remote = EmbeddedMusicRemote.shared
    @Environment(\.windowVisible) private var visible
    let theme: Color
    var height: CGFloat = 5
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let knob = max(11, height + 7)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                if remote.isPlaying, visible, dragFraction == nil {
                    TimelineView(.periodic(from: EmbeddedMusicTick.epoch, by: 0.5)) { _ in
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

private struct EmbeddedCrumbButton: View {
    let name: String
    let path: String
    let systemImage: String?
    let theme: Color
    let isCurrent: Bool
    let onTap: () -> Void
    let onDrop: ([String]) -> Void
    @State private var dropTargeted = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: UIScale.pt(3)) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: UIScale.pt(10)))
                }
                Text(name).lineLimit(1).presenterBlur(
                    EmbeddedMusicPrivacyState.shared.hides(.music))
            }
            .font(.system(size: UIScale.pt(12), weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? AnyShapeStyle(theme) : AnyShapeStyle(.secondary))
            .padding(.horizontal, UIScale.pt(7))
            .padding(.vertical, UIScale.pt(4))
            .background(
                dropTargeted ? theme.opacity(0.2) : .clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(6))
            )
        }
        .buttonStyle(.edith(.borderless))
        .dropDestination(for: String.self) { paths, _ in
            guard !isCurrent else { return false }
            onDrop(paths)
            return !paths.isEmpty
        } isTargeted: {
            dropTargeted = $0 && !isCurrent
        }
    }
}

private struct EmbeddedMusicFolderRow: View {
    let folder: EmbeddedMusicFolder
    let theme: Color
    let location: String?
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onDrop: ([String]) -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var trackCount: Int?

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
                            .font(.edithText(.body).weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                            .presenterBlur(EmbeddedMusicPrivacyState.shared.hides(.music))
                        Text(
                            location ?? trackCount.map { "\($0) track\($0 == 1 ? "" : "s")" }
                                ?? "Folder"
                        )
                        .presenterBlur(
                            location != nil && EmbeddedMusicPrivacyState.shared.hides(.music)
                        )
                        .font(.edithText(.subheadline))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: UIScale.pt(22)))
                    .foregroundStyle(theme)
            }
            .buttonStyle(.edith(.borderless))
            .help("Play this folder")
            .opacity(hovering || trackCount == 0 ? 1 : 0.55)
            .frame(width: EmbeddedMusicRowColumn.value, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: EmbeddedMusicRowColumn.trailing)
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
            folderMenu(
                folder, onOpen: onOpen, onPlay: onPlay, onRename: onRename, onDelete: onDelete)
        }
        .pageTask(id: folder.relativePath) {
            let path = folder.relativePath
            trackCount = EmbeddedTrackMeta.cachedTrackCount(under: path)
            let count = await EmbeddedTrackMeta.remoteTrackCount(under: path)
            guard !Task.isCancelled else { return }
            trackCount = count
        }
    }
}

struct EmbeddedMoveTarget: Identifiable, Equatable {
    let name: String
    let path: String
    var id: String { path }
}

private struct EmbeddedMusicPageRow: View {
    let track: EmbeddedTrack
    let location: String?
    let isCurrent: Bool
    let isPlaying: Bool
    let theme: Color
    let blur: Bool
    let moveTargets: [EmbeddedMoveTarget]
    let isFavourite: Bool
    let onOpenDetails: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onMove: (String) -> Void
    let onToggle: () -> Void
    let onToggleFavourite: () -> Void
    let onOpenFolder: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var duration: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Button(action: onOpenDetails) {
                EmbeddedPageArtworkThumb(track: track, size: 34)
            }
            .buttonStyle(.edith(.borderless))
            .help("Show details")
            Button(action: onToggle) {
                HStack(spacing: UIScale.pt(10)) {
                    VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                        Text(track.title)
                            .font(.edithText(.body))
                            .lineLimit(1)
                            .foregroundStyle(isCurrent ? theme : .primary)
                            .presenterBlur(blur)
                        if let location {
                            Text(location)
                                .font(.edithText(.subheadline))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .presenterBlur(EmbeddedMusicPrivacyState.shared.hides(.music))
                        }
                    }
                    Spacer()
                    if isCurrent {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(theme)
                    }
                    Text(duration ?? "")
                        .font(.edithText(.subheadline))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(width: EmbeddedMusicRowColumn.value, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))

            Button(action: onToggleFavourite) {
                Image(systemName: isFavourite ? "heart.fill" : "heart")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(isFavourite ? AnyShapeStyle(theme) : AnyShapeStyle(.secondary))
                    .frame(width: EmbeddedMusicRowColumn.trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help(isFavourite ? "Remove from favourites" : "Add to favourites")
            .opacity(hovering || isFavourite ? 1 : 0)
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
            trackMenu(
                track, moveTargets: moveTargets, isFavourite: isFavourite,
                onOpenDetails: onOpenDetails, onRename: onRename, onDelete: onDelete,
                onMove: onMove, onToggleFavourite: onToggleFavourite,
                onOpenFolder: onOpenFolder)
        }
        .pageTask(id: track.id) {
            duration = EmbeddedTrackMeta.cachedDurationLabel(for: track)
            let value = await EmbeddedTrackMeta.durationLabel(for: track)
            guard !Task.isCancelled else { return }
            duration = value
        }
    }
}

@ViewBuilder
private func folderMenu(
    _ folder: EmbeddedMusicFolder, onOpen: @escaping () -> Void, onPlay: @escaping () -> Void,
    onRename: @escaping () -> Void, onDelete: @escaping () -> Void
) -> some View {
    Button("Play", action: onPlay)
    Button("Open", action: onOpen)
    Button("Show in Finder") {
        EmbeddedMusicRemote.shared.send(.revealFolder, path: folder.relativePath)
    }
    Button("Rename", action: onRename)
    Button("Move to Trash", role: .destructive, action: onDelete)
}

@ViewBuilder
private func trackMenu(
    _ track: EmbeddedTrack, moveTargets: [EmbeddedMoveTarget], isFavourite: Bool,
    onOpenDetails: @escaping () -> Void, onRename: @escaping () -> Void,
    onDelete: @escaping () -> Void, onMove: @escaping (String) -> Void,
    onToggleFavourite: @escaping () -> Void, onOpenFolder: @escaping () -> Void
) -> some View {
    Button(
        isFavourite ? "Remove from Favourites" : "Add to Favourites", action: onToggleFavourite)
    Button("Show Details", action: onOpenDetails)
    Button("Open Enclosing Folder", action: onOpenFolder)
    Button("Show in Finder") {
        remoteReveal(track)
    }
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

struct EmbeddedMusicLibrarySkeleton: View {
    let grid: Bool
    @State private var width: CGFloat = 0

    var body: some View {
        SkeletonGroup {
            if grid {
                let layout = EmbeddedMusicTile.layout(count: 12, available: width)
                LazyVGrid(columns: layout.columns, spacing: UIScale.pt(16)) {
                    ForEach(0..<12, id: \.self) { index in
                        VStack(alignment: .center, spacing: UIScale.pt(7)) {
                            SkeletonBlock(width: layout.art, height: layout.art, corner: 8)
                            SkeletonBlock(width: index.isMultiple(of: 2) ? 96 : 78, height: 12)
                            SkeletonBlock(width: 64, height: 10)
                        }
                        .padding(UIScale.pt(EmbeddedMusicTile.inset))
                    }
                }
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    width = $0
                }
            } else {
                LazyVStack(spacing: UIScale.pt(2)) {
                    ForEach(0..<8, id: \.self) { index in
                        HStack(spacing: UIScale.pt(10)) {
                            SkeletonBlock(width: 34, height: 34, corner: 7.5)
                            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                                SkeletonBlock(
                                    width: index.isMultiple(of: 2) ? 164 : 132, height: 13)
                                SkeletonBlock(width: 92, height: 10.5)
                            }
                            Spacer()
                            SkeletonBlock(width: 32, height: 10)
                                .frame(width: EmbeddedMusicRowColumn.value, alignment: .trailing)
                            SkeletonBlock(width: 16, height: 16, corner: 8)
                                .frame(width: EmbeddedMusicRowColumn.trailing)
                        }
                        .padding(.vertical, UIScale.pt(6))
                        .padding(.horizontal, UIScale.pt(8))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading music library")
    }
}

private enum EmbeddedMusicRowColumn {
    static var value: CGFloat { UIScale.pt(56) }
    static var trailing: CGFloat { UIScale.pt(16) }
}

enum EmbeddedMusicTile {
    struct Layout {
        let columns: [GridItem]
        let art: Double
    }

    static let art = 118.0
    static let maximumArt = 200.0
    static let inset = 6.0
    static let spacing = 14.0

    static func columnCount(count: Int, fit: Int) -> Int {
        let fit = max(1, fit)
        guard count > fit else { return max(1, count) }
        let smallest = max(1, (fit + 1) * 2 / 3)
        let candidates = Array(stride(from: fit, through: smallest, by: -1))
        if let even = candidates.first(where: { count.isMultiple(of: $0) }) { return even }
        return candidates.max {
            Double(count % $0) / Double($0) < Double(count % $1) / Double($1)
        } ?? fit
    }

    static func layout(count: Int, available: CGFloat) -> Layout {
        let gap = UIScale.pt(spacing)
        let minimum = UIScale.pt(art + inset * 2)
        let fit = available > 0 ? Int((available + gap) / (minimum + gap)) : 1
        let columns = columnCount(count: count, fit: fit)
        let cell = (available - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let fitted = Double(cell / UIScale.pt(1)) - inset * 2
        return Layout(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: gap, alignment: .top), count: columns),
            art: min(maximumArt, max(art, fitted)))
    }
}

extension EnvironmentValues {
    @Entry var musicTileArt = EmbeddedMusicTile.art
}

private struct EmbeddedMusicFolderTile: View {
    let folder: EmbeddedMusicFolder
    let theme: Color
    let location: String?
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onDrop: ([String]) -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.musicTileArt) private var art
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var trackCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: onOpen) {
                    ZStack {
                        RoundedRectangle(cornerRadius: UIScale.pt(12))
                            .fill(theme.opacity(0.16))
                        Image(systemName: "folder.fill")
                            .font(.system(size: UIScale.pt(34)))
                            .foregroundStyle(theme)
                    }
                    .frame(width: UIScale.pt(art), height: UIScale.pt(art))
                }
                .buttonStyle(.edith(.borderless))
                .accessibilityLabel(
                    EmbeddedMusicPrivacyState.shared.hides(.music)
                        ? "Open folder" : "Open \(folder.name)")
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: UIScale.pt(24)))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, theme)
                }
                .buttonStyle(.edith(.borderless))
                .help("Play this folder")
                .opacity(hovering ? 1 : 0)
                .padding(UIScale.pt(7))
            }

            VStack(spacing: UIScale.pt(1)) {
                Text(folder.name)
                    .font(.edithText(.callout).weight(.medium))
                    .lineLimit(1)
                    .presenterBlur(EmbeddedMusicPrivacyState.shared.hides(.music))
                Text(location ?? trackCount.map { "\($0) track\($0 == 1 ? "" : "s")" } ?? "Folder")
                    .font(.edithText(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .presenterBlur(
                        location != nil && EmbeddedMusicPrivacyState.shared.hides(.music))
            }
            .frame(width: UIScale.pt(art))
        }
        .padding(UIScale.pt(6))
        .background(
            dropTargeted
                ? theme.opacity(0.16) : hovering ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(10))
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
            folderMenu(
                folder, onOpen: onOpen, onPlay: onPlay, onRename: onRename, onDelete: onDelete)
        }
        .pageTask(id: folder.relativePath) {
            let path = folder.relativePath
            trackCount = EmbeddedTrackMeta.cachedTrackCount(under: path)
            let count = await EmbeddedTrackMeta.remoteTrackCount(under: path)
            guard !Task.isCancelled else { return }
            trackCount = count
        }
    }
}

private struct EmbeddedMusicTrackTile: View {
    let track: EmbeddedTrack
    let location: String?
    let isCurrent: Bool
    let isPlaying: Bool
    let theme: Color
    let blur: Bool
    let moveTargets: [EmbeddedMoveTarget]
    let isFavourite: Bool
    let onOpenDetails: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onMove: (String) -> Void
    let onToggle: () -> Void
    let onToggleFavourite: () -> Void
    let onOpenFolder: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.musicTileArt) private var art
    @State private var duration: String?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            ZStack(alignment: .topTrailing) {
                Button(action: onToggle) {
                    EmbeddedPageArtworkThumb(track: track, size: art)
                        .overlay(alignment: .bottomTrailing) {
                            Image(
                                systemName: isCurrent && isPlaying
                                    ? "pause.circle.fill" : "play.circle.fill"
                            )
                            .font(.system(size: UIScale.pt(24)))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, theme)
                            .opacity(hovering || isCurrent ? 1 : 0)
                            .padding(UIScale.pt(7))
                        }
                }
                .buttonStyle(.edith(.borderless))
                Button(action: onToggleFavourite) {
                    Image(systemName: isFavourite ? "heart.fill" : "heart")
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                        .foregroundStyle(isFavourite ? theme : .white)
                        .shadow(color: .black.opacity(0.5), radius: UIScale.pt(2))
                }
                .buttonStyle(.edith(.borderless))
                .help(isFavourite ? "Remove from favourites" : "Add to favourites")
                .opacity(hovering || isFavourite ? 1 : 0)
                .padding(UIScale.pt(7))
            }

            Button(action: onOpenDetails) {
                VStack(spacing: UIScale.pt(1)) {
                    Text(track.title)
                        .font(.edithText(.callout))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(isCurrent ? theme : .primary)
                        .presenterBlur(blur)
                    Text(location ?? duration ?? " ")
                        .font(.edithText(.subheadline))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .presenterBlur(
                            location != nil && EmbeddedMusicPrivacyState.shared.hides(.music))
                }
                .frame(width: UIScale.pt(art))
            }
            .buttonStyle(.edith(.borderless))
            .help("Show details")
        }
        .padding(UIScale.pt(6))
        .background(
            isCurrent
                ? Color.primary.opacity(0.08) : hovering ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(10))
        )
        .onHover { hovering = $0 }
        .draggable(track.relativePath)
        .contextMenu {
            trackMenu(
                track, moveTargets: moveTargets, isFavourite: isFavourite,
                onOpenDetails: onOpenDetails, onRename: onRename, onDelete: onDelete,
                onMove: onMove, onToggleFavourite: onToggleFavourite,
                onOpenFolder: onOpenFolder)
        }
        .pageTask(id: track.id) {
            duration = EmbeddedTrackMeta.cachedDurationLabel(for: track)
            let value = await EmbeddedTrackMeta.durationLabel(for: track)
            guard !Task.isCancelled else { return }
            duration = value
        }
    }
}

struct EmbeddedMusicDetailOverlay: View {
    @State private var presenter = EmbeddedMusicDetailPresenter.shared
    @State private var remote = EmbeddedMusicRemote.shared
    @AppStorage(
        AppStorageKeys.General.theme,
        store: SharedDefaults.store) private var themeName =
        "accent"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deleteTarget: EmbeddedTrack?

    private var theme: Color { themeColor(themeName) }

    private var sheetShape: String? {
        presenter.track.map { $0.isVideo ? "video" : "audio" }
    }

    var body: some View {
        ZStack {
            if let track = presenter.track {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { presenter.dismiss() }
                    .transition(.opacity)
                GeometryReader { geometry in
                    EmbeddedMusicDetailSheet(
                        track: track,
                        availableSize: geometry.size,
                        theme: theme,
                        beginRename: presenter.beginRename,
                        onRename: { remote.rename(track, to: $0) },
                        onDelete: {
                            presenter.dismiss()
                            deleteTarget = track
                        },
                        onOpenFolder: {
                            remote.send(.openMusic, path: $0, target: "folder")
                        },
                        onClose: { presenter.dismiss() }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(16)))
                    .shadow(color: .black.opacity(0.45), radius: UIScale.pt(40), y: UIScale.pt(16))
                    .padding(UIScale.pt(24))
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Button("Close", action: presenter.dismiss)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: sheetShape)
        .animation(
            Motion.animation(.smooth(duration: 0.32), reduceMotion: reduceMotion),
            value: presenter.renameArmed
        )
        .onChange(of: remote.currentFile) { presenter.followCurrent() }
        .alert(
            "Move to Trash?",
            isPresented: Binding(
                get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { track in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Move to Trash", role: .destructive) {
                remote.delete(track)
                deleteTarget = nil
            }
        } message: { track in
            Text(
                EmbeddedMusicPrivacyState.shared.hides(.music)
                    ? "This track will be moved to the Trash."
                    : "\"\(track.title)\" will be moved to the Trash."
            )
        }
    }
}

struct EmbeddedMusicDetailSheet: View {
    let track: EmbeddedTrack
    let availableSize: CGSize
    let theme: Color
    let beginRename: Bool
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onOpenFolder: (String) -> Void
    let onClose: () -> Void
    @State private var remote = EmbeddedMusicRemote.shared
    @State private var presenter = EmbeddedMusicDetailPresenter.shared
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var namedTrack: URL?
    @FocusState private var nameFocused: Bool
    @State private var sourceURL: URL?
    @State private var contentHeight: CGFloat?

    private var dark: Bool { scheme == .dark }
    private var isCurrent: Bool { remote.currentFile == track.relativePath }
    private var isPlaying: Bool { isCurrent && remote.isPlaying }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            header
            ScrollView {
                content.onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    contentHeight = $0
                }
            }
        }
        .frame(
            width: min(
                PresentationMetrics.width(track.isVideo ? 760 : 400),
                max(0, availableSize.width - UIScale.pt(48))),
            height: sheetHeight
        )
        .background(sheetBackground)
        .onChange(of: track.id, initial: true) {
            name = track.url.deletingPathExtension().lastPathComponent
            namedTrack = track.id
            presenter.armRename(false)
        }
        .pageTask(id: track.id) {
            if let data = try? await remote.request(
                "music.ui.source", action: .init(kind: .startTrack, path: track.relativePath))
            {
                sourceURL = try? JSONDecoder().decode(URL.self, from: data)
            }
            if beginRename { nameFocused = true }
        }
    }

    private var sheetHeight: CGFloat {
        let limit = min(
            PresentationMetrics.height(track.isVideo ? 650 : 560),
            max(0, availableSize.height - UIScale.pt(48)))
        guard let contentHeight else { return limit }
        return min(limit, contentHeight + UIScale.pt(Self.headerHeight))
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
        HStack(spacing: UIScale.pt(8)) {
            Spacer()
            headerButton("trash", tint: .red, help: "Move to Trash", action: onDelete)
            headerButton("xmark", tint: .secondary, help: "Close", action: onClose)
        }
        .padding(.horizontal, UIScale.pt(16))
        .padding(.top, UIScale.pt(14))
    }

    private func headerButton(
        _ symbol: String, tint: some ShapeStyle, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: UIScale.pt(26), height: UIScale.pt(26))
                .background(DashSkin.paper2(dark).opacity(0.6), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .help(help)
    }

    private var content: some View {
        VStack(spacing: UIScale.pt(0)) {
            VStack(spacing: UIScale.pt(20)) {
                stage
                    .padding(.top, UIScale.pt(2))
                titleField
                folderPath
                if isCurrent, !track.isVideo {
                    playerBlock
                }
                if let sourceURL, sourceURL.scheme == "https" {
                    youtubeLink(sourceURL)
                }
            }
            renameReveal
        }
        .padding(.horizontal, UIScale.pt(28))
        .padding(.bottom, UIScale.pt(28))
        .padding(.top, UIScale.pt(6))
    }

    @ViewBuilder private var stage: some View {
        if track.isVideo {
            EmbeddedMusicVideoArtwork(track: track)
                .id(track.id)
                .presenterCover(EmbeddedMusicPrivacyState.shared.hides(.music))
                .transition(.opacity)
        } else {
            artwork
                .transition(.opacity)
        }
    }

    private var folderPath: some View {
        let parent = (track.relativePath as NSString).deletingLastPathComponent
        return Button {
            onOpenFolder(parent)
            onClose()
        } label: {
            HStack(spacing: UIScale.pt(5)) {
                Image(systemName: "folder")
                Text(parent.isEmpty ? "Music" : parent.replacingOccurrences(of: "/", with: " / "))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .presenterBlur(EmbeddedMusicPrivacyState.shared.hides(.music))
                Image(systemName: "arrow.right")
                    .font(.system(size: UIScale.pt(8), weight: .semibold))
            }
            .font(.system(size: UIScale.pt(11), weight: .medium))
            .foregroundStyle(theme)
            .padding(.horizontal, UIScale.pt(10))
            .padding(.vertical, UIScale.pt(6))
            .background(theme.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.edith(.borderless))
        .help("Show this folder in Music")
    }

    private var artwork: some View {
        EmbeddedPageArtworkThumb(track: track, size: 196)
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
                .buttonStyle(.edith(.borderless))
                .embeddedLiquidGlass(in: Circle(), tint: theme, interactive: true, dark: dark)
                .shadow(color: .black.opacity(0.28), radius: UIScale.pt(8), y: UIScale.pt(3))
                .help(isPlaying ? "Pause" : "Play")
                .offset(x: UIScale.pt(10), y: UIScale.pt(10))
            }
    }

    private var titleField: some View {
        TextField("Track name", text: nameBinding)
            .textFieldStyle(.plain)
            .font(.edithText(.title2).weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(DashSkin.ink(dark))
            .presenterBlur(EmbeddedMusicPrivacyState.shared.hides(.music))
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

    private var playerBlock: some View {
        VStack(spacing: UIScale.pt(8)) {
            EmbeddedSeekBar(theme: theme, height: UIScale.pt(5))
            ZStack {
                HStack {
                    ticker { Text(EmbeddedTrackMeta.timeLabel(remote.elapsed)) }
                    Spacer()
                    ticker {
                        Text(
                            "-"
                                + EmbeddedTrackMeta.timeLabel(
                                    max(remote.duration - remote.elapsed, 0)))
                    }
                }
                Label(isPlaying ? "Now Playing" : "Paused", systemImage: "waveform")
                    .font(.edithText(.subheadline).weight(.medium))
                    .foregroundStyle(theme)
            }
            .font(.edithText(.subheadline))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func ticker<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View
    {
        if isPlaying {
            TimelineView(.periodic(from: EmbeddedMusicTick.epoch, by: 1)) { _ in content() }
        } else {
            content()
        }
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
        .buttonStyle(.edith(.borderless))
    }

    private var renameReveal: some View {
        Button(action: commitRename) {
            Label("Rename", systemImage: "checkmark")
                .frame(maxWidth: .infinity)
                .frame(height: UIScale.pt(Self.renameButtonHeight))
                .foregroundStyle(.white)
        }
        .buttonStyle(.edith(.borderless))
        .background(theme, in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .font(.edithText(.callout).weight(.semibold))
        .padding(.top, UIScale.pt(Self.renameButtonGap))
        .frame(height: canRename ? UIScale.pt(Self.renameRowHeight) : 0, alignment: .top)
        .clipped()
        .allowsHitTesting(canRename)
    }

    private static let headerHeight = 40.0
    private static let renameButtonHeight = 40.0
    private static let renameButtonGap = 20.0
    private static var renameRowHeight: Double { renameButtonHeight + renameButtonGap }

    private var nameBinding: Binding<String> {
        Binding(
            get: { name },
            set: { value in
                name = value
                presenter.armRename(isRenameable(value))
            })
    }

    private var canRename: Bool { presenter.renameArmed && namedTrack == track.id }

    private func isRenameable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != track.url.deletingPathExtension().lastPathComponent
    }

    private func commitRename() {
        if isRenameable(name) { onRename(name) }
        onClose()
    }
}

@available(macOS 26, *)
private enum EmbeddedGlassStyle {
    static func make(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension EnvironmentValues {
    @Entry var musicLiquidGlass = true
}

private struct EmbeddedLiquidGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    let dark: Bool
    @Environment(\.musicLiquidGlass) private var liquidGlass

    func body(content: Content) -> some View {
        if #available(macOS 26, *), liquidGlass {
            content.glassEffect(
                EmbeddedGlassStyle.make(tint: tint, interactive: interactive), in: shape)
        } else if let tint {
            content.background(tint, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.14 : 0.1), lineWidth: 1))
        }
    }
}

extension View {
    func embeddedLiquidGlass<S: InsettableShape>(
        in shape: S, tint: Color? = nil, interactive: Bool = false, dark: Bool = false
    ) -> some View {
        modifier(
            EmbeddedLiquidGlass(shape: shape, tint: tint, interactive: interactive, dark: dark))
    }
}

struct EmbeddedMusicFooter: View {
    @State private var accounts = EmbeddedMusicAccounts.shared
    init(accounts: EmbeddedMusicAccounts? = nil) {
        _accounts = State(initialValue: accounts ?? .shared)
    }
    @State private var playerOptionsPresented = false
    @State private var remote = EmbeddedMusicRemote.shared
    @Environment(\.windowVisible) private var visible
    @AppStorage(
        AppStorageKeys.General.theme,
        store: SharedDefaults.store) private var themeName =
        "accent"
    @AppStorage(AppStorageKeys.Music.barCollapsed, store: SharedDefaults.store) private
        var collapsed = false
    private var presenterState = EmbeddedMusicPrivacyState.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: Color { themeColor(themeName) }
    private var blur: Bool { presenterState.active }
    private var dark: Bool { scheme == .dark }

    private var barHeight: CGFloat { accounts.selected == .spotify ? 80 : Self.expandedHeight }
    static let expandedHeight: CGFloat = 64
    static let collapsedHeight: CGFloat = 2

    var body: some View {
        if accounts.playerReady { playerBar }
    }

    private var playerBar: some View {
        Group {
            if collapsed {
                collapsedLine
            } else {
                expandedBar
            }
        }
        .frame(height: UIScale.pt(collapsed ? Self.collapsedHeight : barHeight))
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: collapsed)
    }

    private var expandedBar: some View {
        HStack(spacing: 0) {
            Group {
                if accounts.selected == .spotify {
                    EmbeddedMusicStreamingControls(accounts: accounts)
                        .padding(.leading, UIScale.pt(20))
                } else if accounts.selected == .youtubeMusic {
                    HStack(spacing: UIScale.pt(12)) {
                        Label("YouTube Music", systemImage: "play.circle")
                            .font(.edithText(.body))
                        Spacer(minLength: UIScale.pt(8))
                        Button("Open player") {
                            EmbeddedMusicRemote.shared.send(.openMusic)
                        }
                        .buttonStyle(.edith(.secondary))
                    }
                    .padding(.leading, UIScale.pt(20))
                } else if let track = remote.current {
                    playing(track)
                } else {
                    idle
                }
            }
            .frame(maxWidth: .infinity)
            collapseToggle
                .padding(.horizontal, UIScale.pt(8))
        }
        .frame(height: UIScale.pt(barHeight))
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    private var collapsedLine: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                Rectangle()
                    .fill(theme)
                    .frame(
                        width: geo.size.width
                            * accounts.progress)
            }
        }
        .frame(height: UIScale.pt(Self.collapsedHeight))
        .frame(maxWidth: .infinity)
    }

    private var collapseToggle: some View {
        Button {
            collapsed = true
            EmbeddedMusicRemote.shared.send(.barCollapsed, value: 1)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: UIScale.pt(10), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: UIScale.pt(24), height: UIScale.pt(24))
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .help("Collapse the player bar")
        .accessibilityLabel("Collapse the player bar")
    }

    private func playing(_ track: EmbeddedTrack) -> some View {
        ViewThatFits(in: .horizontal) {
            playingControls(track, compact: false).frame(minWidth: UIScale.pt(820))
            playingControls(track, compact: true)
        }
    }

    private func playingControls(_ track: EmbeddedTrack, compact: Bool) -> some View {
        HStack(spacing: UIScale.pt(14)) {
            trackInfo(track)
                .frame(maxWidth: .infinity, alignment: .leading)
            transport
            if compact {
                Button {
                    playerOptionsPresented = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.edith(.iconOnly))
                .accessibilityLabel("Playback options")
                .popover(isPresented: $playerOptionsPresented) {
                    VStack(spacing: UIScale.pt(12)) {
                        scrubber
                        ScrollView(.horizontal, showsIndicators: false) { rightControls }
                    }
                    .padding(UIScale.pt(16))
                    .frame(width: PresentationMetrics.width(320))
                }
            } else {
                scrubber
                    .frame(maxWidth: UIScale.pt(420))
                rightControls
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.leading, UIScale.pt(20))
    }

    private func trackInfo(_ track: EmbeddedTrack) -> some View {
        HStack(spacing: UIScale.pt(11)) {
            Button {
                EmbeddedMusicDetailPresenter.shared.show(track)
            } label: {
                EmbeddedPageArtworkThumb(track: track, size: 44)
            }
            .buttonStyle(.edith(.borderless))
            .help(track.isVideo ? "Watch this video" : "Show details")
            Button {
                remote.reveal(track)
            } label: {
                HStack(spacing: UIScale.pt(11)) {
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(track.title)
                            .font(.edithText(.body).weight(.semibold))
                            .lineLimit(1)
                            .presenterBlur(blur)
                        Text(remote.isPlaying ? "Now playing" : "Paused")
                            .font(.edithText(.subheadline))
                            .foregroundStyle(.secondary)
                            .frame(width: UIScale.pt(78), alignment: .leading)
                    }
                    EmbeddedPlaybackWave(
                        playing: remote.isPlaying && visible, color: theme.opacity(0.9),
                        maxHeight: UIScale.pt(13))
                }
            }
            .buttonStyle(.edith(.borderless))
            .help("Show this track in Music")
        }
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
        .buttonStyle(.edith(.borderless))
        .embeddedLiquidGlass(in: Circle(), tint: tint, interactive: true, dark: dark)
    }

    private var scrubber: some View {
        HStack(spacing: UIScale.pt(10)) {
            timeTicker {
                Text(EmbeddedTrackMeta.timeLabel(remote.elapsed))
                    .frame(width: UIScale.pt(42), alignment: .trailing)
            }
            EmbeddedSeekBar(theme: theme, height: UIScale.pt(4))
            timeTicker {
                Text("-" + EmbeddedTrackMeta.timeLabel(max(remote.duration - remote.elapsed, 0)))
                    .frame(width: UIScale.pt(46), alignment: .leading)
            }
        }
        .font(.edithText(.subheadline))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func timeTicker<Content: View>(@ViewBuilder _ content: @escaping () -> Content)
        -> some View
    {
        if remote.isPlaying, visible {
            TimelineView(.periodic(from: EmbeddedMusicTick.epoch, by: 1)) { _ in content() }
        } else {
            content()
        }
    }

    private var rightControls: some View {
        HStack(spacing: UIScale.pt(10)) {
            if let track = remote.current {
                let liked = remote.favouritePaths.contains(track.relativePath)
                glassButton(
                    liked ? "heart.fill" : "heart", diameter: 34, iconSize: 12,
                    iconColor: liked ? .white : .secondary,
                    tint: liked ? theme : nil
                ) {
                    remote.toggleFavourite(track)
                }
                .help(liked ? "Remove from favourites" : "Add to favourites")
            }
            glassButton(
                "shuffle", diameter: 34, iconSize: 12,
                iconColor: remote.shuffling ? .white : .secondary,
                tint: remote.shuffling ? theme : nil
            ) {
                remote.toggleShuffle()
            }
            .help(remote.shuffling ? "Shuffling this folder and everything in it" : "Play in order")
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
                    .settingsCaption()
                Slider(
                    value: Binding(get: { remote.volume }, set: { remote.setVolume($0) }),
                    in: 0...1
                )
                .controlSize(.mini)
                .tint(theme)
                .frame(width: UIScale.pt(80))
            }
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(7))
            .embeddedLiquidGlass(in: Capsule(), dark: dark)
        }
    }

    private var idle: some View {
        HStack(spacing: UIScale.pt(12)) {
            Image(systemName: "music.note")
                .font(.system(size: UIScale.pt(14)))
                .foregroundStyle(.secondary)
            Text("Nothing playing")
                .font(.edithText(.callout))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                remote.send(.openMusic)
            } label: {
                Text("Browse music")
                    .font(.edithText(.subheadline).weight(.medium))
                    .foregroundStyle(theme)
            }
            .buttonStyle(.edith(.toolbar))
        }
        .padding(.leading, UIScale.pt(20))
    }
}

private struct EmbeddedPageArtworkThumb: View {
    let track: EmbeddedTrack
    let size: CGFloat
    @State private var artwork: NSImage?

    init(track: EmbeddedTrack, size: CGFloat = 36) {
        self.track = track
        self.size = size
        _artwork = State(initialValue: EmbeddedTrackMeta.artworkCached(for: track))
    }

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
                        .font(.system(size: UIScale.pt(size * 0.36)))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: UIScale.pt(size), height: UIScale.pt(size))
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(size * 0.22), style: .continuous))
        .presenterCover(EmbeddedMusicPrivacyState.shared.hides(.music))
        .pageTask(id: track.id) {
            if track.isVideo, EmbeddedTrackMeta.artworkCached(for: track) == nil {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            let loaded = await EmbeddedTrackMeta.artwork(for: track)
            guard !Task.isCancelled else { return }
            artwork = loaded
        }
    }
}

enum EmbeddedMusicBarProgress {
    static func fraction(elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }
}

struct EmbeddedMusicSidebarPill: View {
    let theme: Color
    let expand: () -> Void
    @State private var remote = EmbeddedMusicRemote.shared
    @State private var accounts = EmbeddedMusicAccounts.shared
    @Environment(\.windowVisible) private var visible
    @Environment(\.colorScheme) private var scheme
    static let height: CGFloat = 40

    private var progress: Double {
        accounts.progress
    }

    private var showsProgress: Bool {
        accounts.playerTitle != nil && accounts.selected != .youtubeMusic
    }

    var body: some View {
        Button(action: expand) {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                HStack(spacing: UIScale.pt(8)) {
                    Image(systemName: accounts.playerTitle == nil ? "music.note" : "chevron.up")
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(
                            accounts.playerTitle == nil
                                ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme)
                        )
                        .frame(width: UIScale.pt(16))
                    Text(accounts.playerTitle ?? "Nothing playing")
                        .font(.edithText(.caption)).fontWeight(.medium)
                        .foregroundStyle(accounts.playerTitle == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .presenterBlur(EmbeddedMusicPrivacyState.shared.hides(.music))
                    Spacer(minLength: 0)
                    if accounts.playerTitle != nil {
                        EmbeddedPlaybackWave(
                            playing: accounts.isPlaying && visible,
                            color: theme.opacity(0.9), maxHeight: UIScale.pt(10))
                    }
                }
                if showsProgress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.12))
                            Capsule()
                                .fill(theme)
                                .frame(width: max(UIScale.pt(2), geo.size.width * progress))
                        }
                    }
                    .frame(height: UIScale.pt(2))
                }
            }
            .padding(.horizontal, UIScale.pt(9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: UIScale.pt(Self.height))
            .background(
                Color.primary.opacity(scheme == .dark ? 0.07 : 0.05),
                in: RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous))
        }
        .buttonStyle(.edith(.borderless))
        .help("Show the player bar")
        .accessibilityLabel("Show the player bar")
        .accessibilityValue(accounts.playerTitle ?? "Nothing playing")
    }
}
