import EdithKit
import Foundation
import Observation

struct SpotifyCatalogItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let uri: String
    let kind: String
    let title: String
    let subtitle: String
    var artwork: String?
    var duration: Double = 0
    var album: String?
    var description: String?
    var owner: String?
    var position: Int?

    var stableURI: String { uri }
    var playable: Bool { ["track", "episode", "album", "playlist", "artist"].contains(kind) }
    var artworkURL: URL? {
        guard let artwork, let url = URL(string: artwork), url.scheme == "https",
            [
                "i.scdn.co", "mosaic.scdn.co", "image-cdn-ak.spotifycdn.com",
                "image-cdn-fa.spotifycdn.com",
            ]
            .contains(url.host ?? ""),
            url.user == nil, url.password == nil, url.port == nil, !url.path.isEmpty,
            url.host != "i.scdn.co" || url.path.hasPrefix("/image/")
        else { return nil }
        return url
    }

    var valid: Bool {
        let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
        return !id.isEmpty && parts.count == 3 && parts[0] == "spotify" && parts[1] == kind
            && ["track", "episode", "album", "playlist", "artist", "show"].contains(kind)
            && parts[2].utf8.count == 22
            && parts[2].utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            } && duration.isFinite && duration >= 0 && position.map({ $0 >= 0 }) != false
    }
}

enum MusicSpotifyDestination: Equatable, Hashable {
    case home
    case search(String)
    case collection(kind: String, id: String, title: String)
    case library(String)
    case queue
}

@MainActor
@Observable
final class MusicSpotifyLibrary {
    private(set) var playlists: [SpotifyCatalogItem] = []
    private(set) var albums: [SpotifyCatalogItem] = []
    private(set) var artists: [SpotifyCatalogItem] = []
    private(set) var shows: [SpotifyCatalogItem] = []
    private(set) var recent: [SpotifyCatalogItem] = []
    private(set) var topTracks: [SpotifyCatalogItem] = []
    private(set) var topArtists: [SpotifyCatalogItem] = []
    private(set) var items: [SpotifyCatalogItem] = []
    private(set) var queue: [SpotifyCatalogItem] = []
    private(set) var current: SpotifyCatalogItem?
    private(set) var collection: SpotifyCatalogItem?
    private(set) var libraryReady = false
    private(set) var authorizing = false
    private(set) var currentDestination = MusicSpotifyDestination.home
    private(set) var queueVisible = true
    private(set) var shuffle = false
    private(set) var repeatMode = "off"
    private(set) var savedURIs: Set<String> = []
    private(set) var error: String?
    private(set) var nextOffset: Int?
    private(set) var total: Int?
    let load = ContentLoad()
    @ObservationIgnored private var sender: ([String: Any]) -> Void
    @ObservationIgnored private let timeout: Duration
    private var loads: [String: ContentLoad] = [:]
    @ObservationIgnored private var pending: [String: Request] = [:]
    @ObservationIgnored private var deadlines: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var history: [MusicSpotifyDestination] = [.home]
    private(set) var historyIndex = 0
    private var nextCursor: String?
    private var active = false

    private struct Request {
        let key: String
        let kind: String
        let load: ContentLoad
        let ticket: UInt64
        let destination: MusicSpotifyDestination?
        let paging: Bool
        let offset: Int
    }

    private struct Response: Decodable {
        let requestId: String
        var items: [SpotifyCatalogItem]?
        var nextOffset: Int?
        var nextCursor: String?
        var total: Int?
        var current: SpotifyCatalogItem?
        var error: String?
    }

    init(timeout: Duration = .seconds(30), sender: @escaping ([String: Any]) -> Void = { _ in }) {
        self.timeout = timeout
        self.sender = sender
    }

    var loading: Bool { load.isRunning || loads.values.contains { $0.isRunning } }
    var queueLoading: Bool { loads["queue"]?.isRunning == true }
    var queueError: String? { loads["queue"]?.errorMessage }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }
    var canLoadMore: Bool { nextOffset != nil || nextCursor != nil }
    var collectionTitle: String {
        switch currentDestination {
        case .home: "Made for you"
        case .search: "Search"
        case .collection(_, _, let title): title
        case .library(let kind): kind.capitalized
        case .queue: "Queue"
        }
    }

    func configure(sender: @escaping ([String: Any]) -> Void) { self.sender = sender }

    func activate() {
        guard !active else { return }
        active = true
        if libraryReady { loadInitial() }
    }

    func authorize() {
        guard !authorizing else { return }
        authorizing = true
        error = nil
        sender(["action": "authorizeLibrary"])
    }

    func apply(_ event: [String: Any]) {
        if event["event"] as? String == "libraryChanged" {
            if let message = event["error"] as? String { error = message; return }
            switch event["kind"] as? String {
            case "setSaved", "savedState":
                if let uri = event["savedUri"] as? String, let saved = event["saved"] as? Bool {
                    if saved { savedURIs.insert(uri) } else { savedURIs.remove(uri) }
                }
                if event["kind"] as? String == "setSaved", case .library = currentDestination {
                    refresh()
                }
            case "queueAdd": if queueVisible { showQueue() }
            case "createPlaylist":
                request(kind: "playlists")
                if currentDestination == .library("playlists") { refresh() }
            default: break
            }
            return
        }
        if event["event"] as? String == "libraryState" {
            let wasReady = libraryReady
            libraryReady = event["ready"] as? Bool ?? false
            authorizing = event["authorizing"] as? Bool ?? false
            error = event["error"] as? String
            if libraryReady && !wasReady && active { loadInitial() }
            return
        }
        guard event["event"] as? String == "catalog", let requestId = event["requestId"] as? String,
            let request = pending.removeValue(forKey: requestId)
        else { return }
        deadlines.removeValue(forKey: requestId)?.cancel()
        guard request.load.isCurrent(request.ticket),
            request.destination == nil || request.destination == currentDestination
        else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: event),
            let response = try? JSONDecoder().decode(Response.self, from: data)
        else {
            let message = "Spotify returned an invalid library response. Try again."
            request.load.fail(request.ticket, message: message)
            if ownsVisibleError(request) { error = message }
            finishHome()
            return
        }
        if let message = response.error {
            request.load.fail(request.ticket, message: message)
            if ownsVisibleError(request) { error = message }
            finishHome()
            return
        }
        guard let values = response.items, values.allSatisfy(\.valid),
            response.current?.valid != false,
            response.nextOffset == nil || (response.nextOffset ?? 0) > request.offset,
            response.total.map({ $0 >= 0 }) != false
        else {
            let message = "Spotify returned an invalid library response. Try again."
            request.load.fail(request.ticket, message: message)
            if ownsVisibleError(request) { error = message }
            finishHome()
            return
        }
        if request.kind == "queue" {
            queue = values
            current = response.current
        }
        if ["liked", "albums", "artists", "shows"].contains(request.kind) {
            savedURIs.formUnion(values.map(\.uri))
        }
        if request.key == "destination" {
            let merged = request.paging ? items + values : values
            if case .collection = currentDestination {
                items = merged
            } else if currentDestination == .queue {
                items = merged
            } else {
                items = unique(merged)
            }
            if !request.paging || response.current != nil { collection = response.current }
            nextOffset = response.nextOffset
            nextCursor = response.nextCursor
            if !request.paging || response.total != nil { total = response.total }
        } else {
            switch request.kind {
            case "playlists": playlists = unique(values)
            case "albums": albums = unique(values)
            case "artists": artists = unique(values)
            case "shows": shows = unique(values)
            case "recent": recent = unique(values)
            case "topTracks": topTracks = unique(values)
            case "topArtists": topArtists = unique(values)
            case "queue":
                queue = values
                current = response.current
                if currentDestination == .queue { items = values }
            default: break
            }
        }
        request.load.complete(request.ticket, empty: values.isEmpty)
        finishHome()
        if ownsVisibleError(request), load.errorMessage == nil {
            let homeFailed =
                currentDestination == .home
                && loads.contains { $0.key != "queue" && $0.value.errorMessage != nil }
            if !homeFailed { error = nil }
        }
    }

    func search(_ query: String) {
        navigate(to: .search(query.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func open(_ item: SpotifyCatalogItem) {
        guard item.valid else { return }
        if ["track", "episode"].contains(item.kind) {
            play(item)
        } else {
            navigate(to: .collection(kind: item.kind, id: item.id, title: item.title))
        }
    }

    func navigate(to destination: MusicSpotifyDestination) {
        guard destination != currentDestination else { return }
        history = Array(history.prefix(historyIndex + 1)) + [destination]
        historyIndex += 1
        setDestination(destination)
    }

    func back() {
        guard canGoBack else { return }
        historyIndex -= 1
        setDestination(history[historyIndex])
    }

    func forward() {
        guard canGoForward else { return }
        historyIndex += 1
        setDestination(history[historyIndex])
    }

    private func setDestination(_ destination: MusicSpotifyDestination) {
        cancel(key: "destination")
        load.reset()
        currentDestination = destination
        items = []
        collection = nil
        nextOffset = nil
        nextCursor = nil
        total = nil
        error = nil
        refresh()
    }

    func refresh() {
        guard libraryReady else { return }
        switch currentDestination {
        case .home: loadInitial()
        case .search(let query):
            if query.isEmpty {
                load.setContent(empty: true)
            } else {
                request(kind: "search", query: query, destination: currentDestination)
            }
        case .collection(let kind, let id, _):
            request(kind: kind, id: id, destination: currentDestination)
        case .library(let kind): request(kind: kind, destination: currentDestination)
        case .queue: request(kind: "queue", destination: currentDestination)
        }
    }

    func loadMore() {
        guard libraryReady, canLoadMore, !load.isRunning else { return }
        switch currentDestination {
        case .search(let query):
            request(kind: "search", query: query, destination: currentDestination, paging: true)
        case .collection(let kind, let id, _):
            request(kind: kind, id: id, destination: currentDestination, paging: true)
        case .library(let kind):
            request(kind: kind, destination: currentDestination, paging: true)
        default: break
        }
    }

    private func loadInitial() {
        if currentDestination == .home { _ = load.begin() }
        for kind in [
            "playlists", "albums", "artists", "shows", "recent", "topTracks", "topArtists",
        ] {
            request(kind: kind)
        }
        if queueVisible { request(kind: "queue") }
        if currentDestination != .home { refresh() }
    }

    private func finishHome() {
        guard currentDestination == .home else { return }
        var shelfError: String?
        for (kind, owner) in loads where kind != "queue" {
            if owner.isRunning { return }
            if shelfError == nil { shelfError = owner.errorMessage }
        }
        if let message = shelfError {
            if !recent.isEmpty || !topTracks.isEmpty || !topArtists.isEmpty || !playlists.isEmpty
                || !albums.isEmpty || !artists.isEmpty || !shows.isEmpty
            {
                load.setContent()
                error = message
            } else {
                let ticket = load.begin()
                load.fail(ticket, message: message)
            }
        } else {
            load.setContent(empty: recent.isEmpty && topTracks.isEmpty && topArtists.isEmpty)
        }
    }

    private func request(
        kind: String, id: String? = nil, query: String? = nil,
        destination: MusicSpotifyDestination? = nil, paging: Bool = false
    ) {
        let key = destination == nil ? kind : "destination"
        cancel(key: key)
        let owner = destination == nil ? loads[key] ?? ContentLoad() : load
        if destination == nil { loads[key] = owner }
        let ticket = owner.begin()
        let requestId = UUID().uuidString
        let offset = paging ? nextOffset ?? 0 : 0
        pending[requestId] = Request(
            key: key, kind: kind, load: owner, ticket: ticket, destination: destination,
            paging: paging,
            offset: offset)
        var command: [String: Any] = [
            "action": "catalog", "requestId": requestId, "kind": kind,
            "offset": offset,
        ]
        if let id { command["id"] = id }
        if let query { command["query"] = query }
        if paging, let nextCursor { command["cursor"] = nextCursor }
        deadlines[requestId] = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, let request = self.pending.removeValue(forKey: requestId) else {
                return
            }
            self.deadlines.removeValue(forKey: requestId)
            let message = "Spotify took too long to load. Try again."
            request.load.fail(request.ticket, message: message)
            if self.ownsVisibleError(request) { self.error = message }
            self.finishHome()
        }
        sender(command)
    }

    private func cancel(key: String) {
        for (id, request) in pending where request.key == key {
            request.load.cancel(request.ticket)
            pending.removeValue(forKey: id)
            deadlines.removeValue(forKey: id)?.cancel()
        }
    }

    private func ownsVisibleError(_ request: Request) -> Bool {
        request.destination != nil || (currentDestination == .home && request.kind != "queue")
    }

    private func unique(_ values: [SpotifyCatalogItem]) -> [SpotifyCatalogItem] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.uri).inserted }
    }

    func showQueue() {
        queueVisible = true
        if libraryReady { request(kind: "queue") }
    }

    func hideQueue() { queueVisible = false }
    func play(_ item: SpotifyCatalogItem, index: Int? = nil) {
        guard item.valid, item.playable else { return }
        var uri = item.uri
        if let index, index >= 0, ["track", "episode"].contains(item.kind),
            case .collection(let kind, let id, _) = currentDestination,
            ["playlist", "album", "show"].contains(kind)
        {
            uri = "spotify:\(kind):\(id)"
        }
        var command: [String: Any] = ["action": "play", "uri": uri]
        if let index, index >= 0 { command["index"] = item.position ?? index }
        sender(command)
    }

    func addToQueue(_ item: SpotifyCatalogItem) {
        guard item.valid, ["track", "episode"].contains(item.kind) else { return }
        sender(["action": "queueAdd", "uri": item.uri])
    }

    func setSaved(_ item: SpotifyCatalogItem, saved: Bool) {
        guard item.valid else { return }
        sender(["action": "setSaved", "uri": item.uri, "saved": saved])
    }

    func createPlaylist(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        sender(["action": "createPlaylist", "name": name])
    }

    func setShuffle(_ value: Bool) {
        sender(["action": "shuffle", "value": value])
    }

    func setRepeat(_ mode: String) {
        guard ["off", "context", "track"].contains(mode) else { return }
        sender(["action": "repeat", "mode": mode])
    }

    func applyPlaybackState(_ event: [String: Any]) {
        if let value = event["shuffle"] as? Bool { shuffle = value }
        if let mode = event["repeat"] as? String, ["off", "context", "track"].contains(mode) {
            repeatMode = mode
        }
    }

    func reset() {
        for task in deadlines.values { task.cancel() }
        deadlines = [:]
        pending = [:]
        loads = [:]
        load.reset()
        playlists = []; albums = []; artists = []; shows = []
        recent = []; topTracks = []; topArtists = []; items = []; queue = []
        current = nil; collection = nil; nextOffset = nil; nextCursor = nil; total = nil
        savedURIs = []; shuffle = false; repeatMode = "off"
        libraryReady = false; authorizing = false; error = nil; queueVisible = true; active = false
        currentDestination = .home; history = [.home]; historyIndex = 0
    }
}
