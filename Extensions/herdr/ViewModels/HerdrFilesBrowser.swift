import EdithExtensionSupport
import Foundation
import Observation

struct HerdrFilesSource {
    let home: @MainActor () async throws -> String
    let list: @MainActor (String) async throws -> [RemoteFileEntry]
}

@MainActor
@Observable
final class HerdrFilesBrowser {
    let machine: Machine
    private(set) var path: String
    private(set) var entries: [RemoteFileEntry] = []
    private(set) var loading = false
    private(set) var errorMessage: String?
    private(set) var scrollTarget: String?
    var selection: Set<String> = []
    var showHidden = false

    private let source: HerdrFilesSource
    private var history: [String] = []
    private var future: [String] = []
    private var resolvedHome: String?
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    init(machine: Machine, path: String?, source: HerdrFilesSource) {
        self.machine = machine
        self.source = source
        self.path = path ?? (machine.id == Machine.localID ? Self.localHome : "~")
    }

    private static var localHome: String { FileManager.default.homeDirectoryForCurrentUser.path }

    var isLocal: Bool { machine.id == Machine.localID }
    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !future.isEmpty }
    var canGoUp: Bool { FileListing.parentPath(of: path) != nil }

    var visibleEntries: [RemoteFileEntry] {
        showHidden ? entries : entries.filter { !$0.isHidden }
    }

    func start() async {
        guard loadTask == nil else { return }
        await load()
    }

    func load() async {
        let task = scheduleLoad()
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func refresh() {
        _ = scheduleLoad()
    }

    func stopLoading() {
        generation += 1
        loading = false
        loadTask?.cancel()
        loadTask = nil
    }

    func navigate(to newPath: String, recordHistory: Bool = true) {
        let target = expandingHome(newPath)
        guard target != path else { return }
        if recordHistory {
            history.append(path)
            future.removeAll()
        }
        path = target
        entries = []
        selection = []
        _ = scheduleLoad()
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        future.append(path)
        navigate(to: previous, recordHistory: false)
    }

    func goForward() {
        guard let next = future.popLast() else { return }
        history.append(path)
        navigate(to: next, recordHistory: false)
    }

    func goUp() {
        guard let parent = FileListing.parentPath(of: path) else { return }
        navigate(to: parent)
    }

    func goHome() {
        Task {
            guard let home = try? await homeDirectory() else { return }
            navigate(to: home)
        }
    }

    func open(_ entry: RemoteFileEntry) {
        guard entry.isDirectory else { return }
        navigate(to: entry.path)
    }

    func click(_ entry: RemoteFileEntry, extending: Bool) {
        if extending {
            if selection.contains(entry.path) {
                selection.remove(entry.path)
            } else {
                selection.insert(entry.path)
            }
        } else {
            selection = [entry.path]
        }
    }

    func moveSelection(by offset: Int) {
        let rows = visibleEntries
        guard !rows.isEmpty else { return }
        let current = rows.lastIndex { selection.contains($0.path) }
        let next = min(rows.count - 1, max(0, (current ?? (offset > 0 ? -1 : rows.count)) + offset))
        selection = [rows[next].path]
        scrollTarget = rows[next].path
    }

    func openSelection() {
        guard let entry = visibleEntries.first(where: { selection.contains($0.path) }) else {
            return
        }
        open(entry)
    }

    func locate(_ target: String, under root: String? = nil) async -> RemoteFileEntry? {
        if !isLocal, resolvedHome == nil, target == "~" || target.hasPrefix("~/") {
            resolvedHome = try? await source.home()
        }
        let item = expandingHome(target)
        if let entry = await entry(at: item) { return entry }
        guard let root = root.map({ URL(fileURLWithPath: $0).standardized.path }),
            item.hasPrefix(root + "/")
        else { return nil }
        return await search(String(item.dropFirst(root.count + 1)), under: root)
    }

    func reveal(entry: RemoteFileEntry) async {
        guard let parent = FileListing.parentPath(of: entry.path) else { return }
        if parent == path {
            await load()
        } else {
            navigate(to: parent)
            await loadTask?.value
        }
        guard path == parent, entries.contains(where: { $0.path == entry.path }) else { return }
        if entry.name.hasPrefix("."), !showHidden { showHidden = true }
        selection = [entry.path]
        scrollTarget = entry.path
    }

    private func homeDirectory() async throws -> String {
        if let resolvedHome { return resolvedHome }
        let home = try await source.home()
        resolvedHome = home
        return home
    }

    private func expandingHome(_ candidate: String) -> String {
        guard candidate == "~" || candidate.hasPrefix("~/") else { return candidate }
        guard let home = isLocal ? Self.localHome : resolvedHome else { return candidate }
        if candidate == "~" { return home }
        return FileListing.join(parent: home, name: String(candidate.dropFirst(2)))
    }

    private func scheduleLoad() -> Task<Void, Never> {
        loadTask?.cancel()
        generation += 1
        let attempt = generation
        let requested = path
        loading = true
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadDirectory(requested, attempt: attempt)
        }
        loadTask = task
        return task
    }

    private func loadDirectory(_ requested: String, attempt: Int) async {
        var resolved = requested
        if requested == "~" || requested.isEmpty {
            guard let home = try? await homeDirectory() else {
                finish(attempt: attempt, error: "The home folder could not be found.")
                return
            }
            resolved = home
        }
        guard !Task.isCancelled, attempt == generation else { return }
        let result = await listing(resolved)
        guard !Task.isCancelled, attempt == generation else { return }
        if path == requested { path = resolved }
        switch result {
        case let .success(items):
            entries = items
            selection = selection.filter { path in items.contains { $0.path == path } }
            finish(attempt: attempt, error: nil)
        case let .failure(error):
            finish(attempt: attempt, error: error.localizedDescription)
        }
    }

    private func finish(attempt: Int, error: String?) {
        guard attempt == generation else { return }
        errorMessage = error
        loading = false
    }

    private func listing(_ path: String) async -> Result<[RemoteFileEntry], Error> {
        do {
            return .success(try await source.list(path))
        } catch {
            return .failure(error)
        }
    }

    private func entry(at item: String) async -> RemoteFileEntry? {
        guard let parent = FileListing.parentPath(of: item),
            case let .success(items) = await listing(parent)
        else { return nil }
        return Self.match(in: items, named: FileListing.name(of: item))
    }

    private func search(_ relative: String, under root: String) async -> RemoteFileEntry? {
        let head = Self.firstComponent(of: relative)
        var folders = [root]
        var listings = 0
        for depth in 0..<3 {
            var children: [String] = []
            var found: [RemoteFileEntry] = []
            for folder in folders where listings < Self.searchListingLimit {
                listings += 1
                guard case let .success(items) = await listing(folder) else { continue }
                if depth > 0, items.contains(where: { Self.name($0.name, matches: head) }),
                    let entry = await entry(at: folder + "/" + relative)
                {
                    found.append(entry)
                }
                children += Self.searchableFolders(in: items)
            }
            if let newest = found.max(by: {
                ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast)
            }) {
                return newest
            }
            folders = children
        }
        return nil
    }

    private static let searchListingLimit = 160
    nonisolated private static let searchSkippedFolders: Set<String> = [
        "node_modules", "build", "dist", "target", "DerivedData", "Pods", "vendor",
    ]

    nonisolated private static func match(
        in items: [RemoteFileEntry], named spelling: String
    ) -> RemoteFileEntry? {
        items.filter { name($0.name, matches: spelling) }.min { $0.name < $1.name }
    }

    nonisolated private static func searchableFolders(in items: [RemoteFileEntry]) -> [String] {
        items.filter {
            $0.kind == .directory && !$0.name.hasPrefix(".")
                && !searchSkippedFolders.contains($0.name)
        }.map(\.path)
    }

    nonisolated private static func firstComponent(of relative: String) -> String {
        relative.split(separator: "/").first.map(String.init) ?? relative
    }

    nonisolated private static func name(_ name: String, matches spelling: String) -> Bool {
        guard spelling.last == "…" else { return name == spelling }
        let stem = spelling.dropLast()
        return !stem.isEmpty && name.hasPrefix(stem)
    }
}
