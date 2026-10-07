import EdithKit
import SwiftUI

struct MusicSpotifyWorkspace: View {
    let accounts: MusicAccounts
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @State private var search = ""
    @State private var navigationRevision = 0
    @State private var libraryFilter = "playlists"
    @State private var searchFilter = "all"
    @State private var queueTab = "Queue"
    @State private var libraryPresented = false
    @State private var queuePresented = false
    @State private var playlistPresented = false
    @State private var playlistName = ""
    private var library: MusicSpotifyLibrary { accounts.spotify.library }
    private var accent: Color { DashSkin.accent(scheme == .dark) }

    var body: some View {
        Group {
            if compact {
                browser(showsQueue: false)
            } else {
                ViewThatFits(in: .horizontal) {
                    if library.queueVisible { split(showsQueue: true) }
                    split(showsQueue: false)
                    browser(showsQueue: false)
                }
            }
        }
        .font(.edithText(.body))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edithSheet(isPresented: $libraryPresented) {
            sidebar.frame(
                width: PresentationMetrics.width(320), height: PresentationMetrics.height(600))
        }
        .edithSheet(isPresented: $queuePresented) {
            queuePanel.frame(
                width: PresentationMetrics.width(360), height: PresentationMetrics.height(600))
        }
        .edithSheet(isPresented: $playlistPresented) { playlistEditor }
        .pageTask { library.activate() }
        .pageTask(id: search) {
            guard !search.isEmpty else {
                if case .search = library.currentDestination { library.search("") }
                return
            }
            let revision = navigationRevision
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard revision == navigationRevision else { return }
            library.search(search)
        }
        .onChange(of: library.currentDestination) { navigationRevision += 1 }
        .pageRefresh(interval: { .seconds(20) }) {
            if library.queueVisible && !library.queueLoading { library.showQueue() }
        }
    }

    private func split(showsQueue: Bool) -> some View {
        HStack(spacing: 0) {
            sidebar.frame(width: UIScale.pt(210))
            Divider()
            browser(showsQueue: showsQueue).frame(
                minWidth: UIScale.pt(360), idealWidth: UIScale.pt(360), maxWidth: .infinity
            ).layoutPriority(1)
            if showsQueue {
                Divider()
                queuePanel.frame(width: UIScale.pt(240))
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            navigation("Home", symbol: "house", destination: .home)
            navigation("Search", symbol: "magnifyingglass", destination: .search(search))
            Divider()
            HStack {
                Label("Your library", systemImage: "books.vertical")
                    .font(.edithText(.headline))
                Spacer()
                icon("plus", label: "Create playlist") { playlistPresented = true }
                    .disabled(!library.libraryReady)
            }
            VStack(spacing: UIScale.pt(6)) {
                EdithSegmentedPicker(
                    "Library", selection: $libraryFilter,
                    options: ["playlists", "albums"], label: { Self.category($0) })
                EdithSegmentedPicker(
                    "Library categories", selection: $libraryFilter,
                    options: ["artists", "shows"], label: { Self.category($0) })
            }.font(.edithText(.caption))
            navigation("Liked Songs", symbol: "heart.fill", destination: .library("liked"))
            HStack {
                Text(Self.category(libraryFilter)).font(.edithText(.caption)).foregroundStyle(
                    .secondary)
                Spacer()
                Button("See all") { navigate(.library(libraryFilter)) }
                    .font(.edithText(.caption)).buttonStyle(.edith(.borderless))
            }
            ScrollView {
                LazyVStack(spacing: UIScale.pt(3)) {
                    ForEach(sidebarItems) { item in
                        Button {
                            open(item)
                        } label: {
                            HStack(spacing: UIScale.pt(10)) {
                                SpotifyCollectionArtwork(item: item, size: 38)
                                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                                    Text(item.title).font(.edithText(.subheadline)).lineLimit(1)
                                    Text(item.subtitle).font(.edithText(.caption2))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(UIScale.pt(5))
                            .background(
                                selected(item) ? accent.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
                        }
                        .buttonStyle(.edith(.borderless)).presenterBlur(.music)
                        .contextMenu {
                            Button("Play") { library.play(item) }.disabled(!item.playable)
                            Button("Open") { open(item) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(UIScale.pt(16))
        .background(DashSkin.paper2(scheme == .dark).opacity(0.55))
        .onChange(of: libraryFilter) {
            if case .library = library.currentDestination {
                navigate(.library(libraryFilter))
            }
        }
    }

    private var sidebarItems: [SpotifyCatalogItem] {
        switch libraryFilter {
        case "albums": library.albums
        case "artists": library.artists
        case "shows": library.shows
        default: library.playlists
        }
    }

    private func browser(showsQueue: Bool) -> some View {
        VStack(spacing: 0) {
            toolbar(showsQueue: showsQueue)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(24)) {
                    if let error = accounts.spotify.error { PageNotice(error, tone: .error) }
                    if !library.libraryReady {
                        authorization
                    } else {
                        if let error = library.error {
                            PageNotice(
                                error, tone: .error,
                                actions: {
                                    Button("Retry") { library.refresh() }
                                })
                        }
                        PageLoading(
                            state: library.load.state, title: "No music found",
                            message: emptyMessage, layout: .cards,
                            refreshing: library.load.isRefreshing,
                            retry: { library.refresh() }
                        ) {
                            destinationContent
                        }
                    }
                }
                .padding(UIScale.pt(compact ? 18 : 24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func toolbar(showsQueue: Bool) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            icon("sidebar.left", label: "Open music library") { libraryPresented = true }
            icon("chevron.left", label: "Back") {
                navigationRevision += 1; library.back()
            }.disabled(!library.canGoBack)
            if !compact {
                icon("chevron.right", label: "Forward") {
                    navigationRevision += 1; library.forward()
                }.disabled(!library.canGoForward)
            }
            EdithTextField(
                placeholder: "Search songs, artists, albums", text: $search,
                icon: "magnifyingglass", onSubmit: { library.search(search) }
            )
            .disabled(!library.libraryReady)
            icon("list.bullet", label: "Show queue") {
                if !showsQueue {
                    queuePresented = true; library.showQueue()
                } else {
                    library.hideQueue()
                }
            }
            Menu {
                ForEach(MusicProvider.allCases) { provider in
                    Button(provider.title) { accounts.select(provider) }
                }
                Divider()
                Button("Refresh library") { library.refresh() }.disabled(!library.libraryReady)
                Button("Reconnect library") { library.authorize() }
                Divider()
                Button("Disconnect Spotify") { Task { await accounts.spotify.disconnect() } }
            } label: {
                Image(systemName: "person.crop.circle").font(.edithText(.title3))
            }
            .menuStyle(.borderlessButton).fixedSize().help("Music source and account")
        }
        .padding(.horizontal, UIScale.pt(16)).padding(.vertical, UIScale.pt(12))
    }

    @ViewBuilder private var destinationContent: some View {
        switch library.currentDestination {
        case .home: home
        case .search: searchResults
        case .collection: collection
        case .library(let kind):
            Text(kind == "liked" ? "Liked Songs" : Self.category(kind))
                .font(.edithText(.largeTitle)).fontWeight(.bold)
            if kind == "liked" { songs(library.items) } else { collectionGrid(library.items) }
            pagination
        case .queue:
            Text("Queue").font(.edithText(.largeTitle)).fontWeight(.bold)
            songs(library.items)
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(28)) {
            Text(greeting).font(.edithText(.largeTitle)).fontWeight(.bold)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: UIScale.pt(8)) {
                Button {
                    navigate(.library("liked"))
                } label: {
                    HStack {
                        Image(systemName: "heart.fill").foregroundStyle(.white)
                            .frame(width: UIScale.pt(48), height: UIScale.pt(48))
                            .background(
                                LinearGradient(
                                    colors: [.purple, .indigo], startPoint: .topLeading,
                                    endPoint: .bottomTrailing))
                        Text("Liked Songs").font(.edithText(.subheadline)).fontWeight(.semibold)
                        Spacer(minLength: 0)
                    }
                    .background(
                        .primary.opacity(0.06), in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
                }.buttonStyle(.edith(.borderless))
                ForEach(Array(library.playlists.prefix(7))) { item in
                    Button {
                        open(item)
                    } label: {
                        HStack {
                            SpotifyCollectionArtwork(item: item, size: 48)
                            Text(item.title).font(.edithText(.subheadline)).fontWeight(.semibold)
                                .lineLimit(2).presenterBlur(.music)
                            Spacer(minLength: 0)
                        }
                        .background(
                            .primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
                    }.buttonStyle(.edith(.borderless))
                }
            }
            shelf("Your playlists", library.playlists)
            shelf("Recently played", library.recent)
            shelf("On repeat", library.topTracks)
            shelf("Your albums", library.albums)
            shelf("Artists you listen to", library.topArtists)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(24)) {
            Text("Search results").font(.edithText(.largeTitle)).fontWeight(.bold)
            ScrollView(.horizontal) {
                EdithSegmentedPicker(
                    "Search results", selection: $searchFilter,
                    options: ["all", "track", "artist", "album", "playlist", "show"],
                    label: { $0 == "all" ? "All" : Self.category($0) }
                ).fixedSize(horizontal: true, vertical: false)
            }.scrollIndicators(.hidden)
            let values = library.items.filter { searchFilter == "all" || $0.kind == searchFilter }
            if values.contains(where: { ["track", "episode"].contains($0.kind) }) {
                PageSectionHeader("Songs")
                songs(values.filter { ["track", "episode"].contains($0.kind) })
            }
            forKindShelves(values)
            pagination
        }
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(24)) {
            if let item = library.collection {
                HStack(alignment: .bottom, spacing: UIScale.pt(20)) {
                    SpotifyCollectionArtwork(item: item, size: compact ? 96 : 160)
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        Text(Self.category(item.kind)).font(.edithText(.caption)).fontWeight(
                            .semibold)
                        Text(item.title).font(.edithText(.largeTitle)).fontWeight(.bold)
                            .lineLimit(3).presenterBlur(.music)
                        if let description = item.description, !description.isEmpty {
                            Text(description).font(.edithText(.caption)).foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Text(item.subtitle).font(.edithText(.subheadline)).foregroundStyle(
                            .secondary)
                        if let total = library.total {
                            let unit =
                                item.kind == "artist"
                                ? "albums" : item.kind == "show" ? "episodes" : "songs"
                            Text("\(total) \(unit)").font(.edithText(.caption)).foregroundStyle(
                                .secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: UIScale.pt(18)) {
                    Button {
                        library.play(item)
                    } label: {
                        Image(systemName: "play.fill").foregroundStyle(.white)
                            .frame(width: UIScale.pt(48), height: UIScale.pt(48)).background(
                                accent, in: Circle())
                    }.buttonStyle(.edith(.borderless)).accessibilityLabel("Play \(item.title)")
                        .disabled(!item.playable)
                    icon("shuffle", label: "Shuffle collection") {
                        library.setShuffle(!library.shuffle); library.play(item)
                    }
                    .foregroundStyle(library.shuffle ? accent : .secondary)
                    icon(
                        library.savedURIs.contains(item.uri) ? "heart.fill" : "heart",
                        label: "Save collection"
                    ) { toggleSaved(item) }
                }
            } else {
                Text(library.collectionTitle).font(.edithText(.largeTitle)).fontWeight(.bold)
            }
            if library.items.contains(where: { ["track", "episode"].contains($0.kind) }) {
                songs(library.items.filter { ["track", "episode"].contains($0.kind) })
            }
            let collections = library.items.filter { !["track", "episode"].contains($0.kind) }
            if !collections.isEmpty { collectionGrid(collections) }
            pagination
        }
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            HStack {
                EdithSegmentedPicker(
                    "Queue", selection: $queueTab, options: ["Queue", "Recent"], label: { $0 })
                icon("xmark", label: "Close queue") {
                    library.hideQueue(); queuePresented = false
                }
            }
            if queueTab == "Queue" {
                Text("Now playing").font(.edithText(.headline))
                HStack(spacing: UIScale.pt(10)) {
                    MusicStreamingArtwork(url: accounts.spotify.artworkURL, size: 40)
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(
                            accounts.spotify.title.isEmpty
                                ? "Nothing playing" : accounts.spotify.title
                        )
                        .font(.edithText(.subheadline)).foregroundStyle(accent).lineLimit(2)
                        Text(accounts.spotify.artist).font(.edithText(.caption2)).foregroundStyle(
                            .secondary
                        ).lineLimit(1)
                    }.presenterBlur(.music)
                }
            }
            if queueTab == "Queue", library.queueLoading { LoadingIndicator() }
            if queueTab == "Queue", let error = library.queueError {
                PageNotice(
                    error, tone: .error, actions: { Button("Retry") { library.showQueue() } })
            }
            Text(queueTab == "Queue" ? "Next up" : "Recently played").font(.edithText(.headline))
            ScrollView {
                LazyVStack(spacing: UIScale.pt(12)) {
                    ForEach(
                        Array((queueTab == "Queue" ? library.queue : library.recent).enumerated()),
                        id: \.offset
                    ) { _, item in
                        Button {
                            library.play(item)
                        } label: {
                            HStack(spacing: UIScale.pt(8)) {
                                SpotifyCollectionArtwork(item: item, size: 36)
                                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                                    Text(item.title).font(.edithText(.subheadline)).lineLimit(1)
                                    Text(item.subtitle).font(.edithText(.caption2)).foregroundStyle(
                                        .secondary
                                    ).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Text(TrackMeta.timeLabel(item.duration)).font(.edithText(.caption2))
                                    .foregroundStyle(.secondary)
                            }.presenterBlur(.music)
                        }.buttonStyle(.edith(.borderless))
                    }
                    if library.queue.isEmpty && queueTab == "Queue" && !library.queueLoading
                        && library.queueError == nil
                    {
                        Text("Add songs from search or your library.").font(.edithText(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }.scrollIndicators(.hidden)
        }
        .padding(UIScale.pt(16))
        .background(DashSkin.paper2(scheme == .dark).opacity(0.55))
    }

    private var authorization: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            Text("Your Spotify library").font(.edithText(.largeTitle)).fontWeight(.bold)
            Text(
                "Connect your library to browse playlists, Liked Songs, albums, and artists, or search for something new."
            )
            .foregroundStyle(.secondary)
            if library.authorizing {
                HStack {
                    LoadingIndicator(); Text("Finish connecting your library in your browser.")
                }
            } else {
                Button("Connect library") { library.authorize() }.buttonStyle(.edith(.primary))
            }
            if let error = library.error { PageNotice(error, tone: .error) }
        }.padding(.vertical, UIScale.pt(40))
    }

    private var emptyMessage: String {
        if case .search = library.currentDestination {
            return "Try another song, artist, or album."
        }
        return "Saved music and playlists appear here."
    }

    @ViewBuilder private var pagination: some View {
        if library.canLoadMore {
            Button("Load more") { library.loadMore() }.buttonStyle(.edith(.secondary)).disabled(
                library.load.isRunning)
        }
    }

    private func songs(_ values: [SpotifyCatalogItem]) -> some View {
        SpotifySongList(
            items: values, currentURI: accounts.spotify.uri,
            onPlay: { library.play($0) }, onQueue: { library.addToQueue($0) }, onSave: toggleSaved,
            savedURIs: library.savedURIs, onPlayAtIndex: { library.play($0, index: $1) })
    }

    @ViewBuilder private func shelf(_ title: String, _ values: [SpotifyCatalogItem]) -> some View {
        if !values.isEmpty {
            SpotifyCollectionShelf(
                title: title, items: values, onOpen: open,
                onPlay: { library.play($0) })
        }
    }

    private func collectionGrid(_ values: [SpotifyCatalogItem]) -> some View {
        LazyVGrid(
            columns: PageMetrics.cardColumns(compact, minimum: 170, spacing: 16),
            alignment: .leading, spacing: UIScale.pt(20)
        ) {
            ForEach(values) { item in
                Button {
                    open(item)
                } label: {
                    VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                        SpotifyCollectionArtwork(item: item)
                        Text(item.title).font(.edithText(.headline)).lineLimit(2)
                        Text(item.subtitle).font(.edithText(.caption)).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }.presenterBlur(.music)
                }.buttonStyle(.edith(.borderless))
            }
        }
    }

    @ViewBuilder private func forKindShelves(_ values: [SpotifyCatalogItem]) -> some View {
        ForEach(["artist", "album", "playlist", "show"], id: \.self) { kind in
            shelf(Self.category(kind), values.filter { $0.kind == kind })
        }
    }

    private func navigation(_ title: String, symbol: String, destination: MusicSpotifyDestination)
        -> some View
    {
        Button {
            navigate(destination)
        } label: {
            Label(title, systemImage: symbol).font(.edithText(.headline))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, UIScale.pt(7))
                .foregroundStyle(library.currentDestination == destination ? accent : .primary)
        }.buttonStyle(.edith(.borderless))
    }

    private func navigate(_ destination: MusicSpotifyDestination) {
        navigationRevision += 1
        library.navigate(to: destination)
        libraryPresented = false
    }

    private func open(_ item: SpotifyCatalogItem) {
        navigationRevision += 1
        library.open(item)
        libraryPresented = false
    }

    private func selected(_ item: SpotifyCatalogItem) -> Bool {
        if case .collection(_, let id, _) = library.currentDestination { return item.id == id }
        return false
    }

    private func toggleSaved(_ item: SpotifyCatalogItem) {
        library.setSaved(item, saved: !library.savedURIs.contains(item.uri))
    }

    private func icon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: UIScale.pt(24), height: UIScale.pt(26))
        }
        .buttonStyle(.edith(.toolbar)).accessibilityLabel(label).help(label)
    }

    private var playlistEditor: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(20)) {
            Text("Create playlist").font(.edithText(.title2)).fontWeight(.semibold)
            EdithTextField(
                placeholder: "Playlist name", text: $playlistName, icon: "music.note.list")
            HStack {
                Button("Cancel") { playlistPresented = false }.buttonStyle(.edith(.secondary))
                Spacer()
                Button("Create") {
                    library.createPlaylist(playlistName); playlistName = "";
                    playlistPresented = false
                }
                .buttonStyle(.edith(.primary)).disabled(
                    playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(UIScale.pt(24)).frame(width: PresentationMetrics.width(420))
    }

    private static func category(_ kind: String) -> String {
        switch kind {
        case "track", "tracks": "Songs"
        case "album", "albums": "Albums"
        case "artist", "artists": "Artists"
        case "playlist", "playlists": "Playlists"
        case "show", "shows": "Podcasts"
        default: kind.capitalized
        }
    }
}
