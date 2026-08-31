import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class QuinjetFolderPickerModel {
    typealias ResolveHome = @MainActor () async throws -> String
    typealias ListDirectory = @MainActor (String) async throws -> [RemoteFileEntry]

    var path = ""
    private(set) var directory = ""
    private(set) var entries: [RemoteFileEntry] = []
    private(set) var loading = false
    private(set) var errorMessage: String?
    private(set) var selectionIndex = -1

    private let resolveHome: ResolveHome
    private let listDirectory: ListDirectory
    private let debounce: Duration
    private var history: [String] = []
    private var homeDirectory = ""
    private var loadToken = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        debounce: Duration = .milliseconds(120), resolveHome: @escaping ResolveHome,
        listDirectory: @escaping ListDirectory
    ) {
        self.debounce = debounce
        self.resolveHome = resolveHome
        self.listDirectory = listDirectory
    }

    convenience init(session: MachineSession) {
        self.init(
            resolveHome: {
                if session.isLocal {
                    return FileManager.default.homeDirectoryForCurrentUser.path
                }
                if case .disconnected = session.state { session.start() }
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline, !session.state.isConnected {
                    if let message = session.state.failureMessage {
                        throw QuinjetMachineError.connectionFailed(message)
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard session.state.isConnected else {
                    throw QuinjetMachineError.connectionTimedOut
                }
                let home = try await session.homeDirectory().get()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard QuinjetPath.isAbsolute(home) else {
                    throw QuinjetMachineError.homeUnavailable
                }
                return home
            },
            listDirectory: { path in
                try await session.listFiles(path: path).get()
            })
    }

    var selectedEntry: RemoteFileEntry? {
        guard entries.indices.contains(selectionIndex) else { return nil }
        return entries[selectionIndex]
    }

    var canUndo: Bool { !history.isEmpty }

    var canOpenCurrentDirectory: Bool {
        let candidate = normalizedDirectory(path)
        return !directory.isEmpty && !candidate.isEmpty && candidate == directory
    }

    func start() async {
        loading = true
        errorMessage = nil
        do {
            let home = try await resolveHome()
            homeDirectory = home
            await navigate(to: home, recordHistory: false)
        } catch {
            loading = false
            errorMessage = error.localizedDescription
        }
    }

    func editPath(_ value: String) {
        path = value
        selectionIndex = -1
        loadToken += 1
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await refreshForInput()
        }
    }

    func waitForInputRefresh() async {
        await refreshTask?.value
    }

    func navigate(to value: String, recordHistory: Bool = true) async {
        refreshTask?.cancel()
        refreshTask = nil
        let target = normalizedDirectory(value)
        guard !target.isEmpty else { return }
        if recordHistory, !directory.isEmpty, directory != target {
            history.append(directory)
        }
        path = target
        selectionIndex = -1
        await load(target, filter: nil)
    }

    func refresh() async {
        guard !directory.isEmpty else { return }
        await load(directory, filter: nil)
    }

    func moveSelection(by offset: Int) {
        let choices = (canOpenCurrentDirectory ? [-1] : []) + Array(entries.indices)
        guard !choices.isEmpty else { return }
        guard let current = choices.firstIndex(of: selectionIndex) else {
            selectionIndex = offset < 0 ? choices[choices.count - 1] : choices[0]
            return
        }
        selectionIndex = choices[(current + offset + choices.count) % choices.count]
    }

    func selectCurrentDirectory() {
        selectionIndex = -1
    }

    func select(_ entry: RemoteFileEntry) {
        selectionIndex = entries.firstIndex(of: entry) ?? -1
    }

    func completePath() async {
        let candidate =
            selectedEntry.flatMap { navigable($0) ? $0 : nil }
            ?? entries.first(where: navigable)
        guard let candidate else { return }
        await navigate(to: candidate.path)
    }

    func activateSelection() async -> String? {
        guard let selectedEntry else {
            if canOpenCurrentDirectory { return directory }
            let candidates = entries.filter(navigable)
            guard candidates.count == 1, let candidate = candidates.first else { return nil }
            await navigate(to: candidate.path)
            return nil
        }
        guard navigable(selectedEntry) else { return nil }
        await navigate(to: selectedEntry.path)
        return nil
    }

    func undoNavigation() async {
        guard let previous = history.popLast() else { return }
        await navigate(to: previous, recordHistory: false)
    }

    func goUp() async {
        guard let parent = FileListing.parentPath(of: directory) else { return }
        await navigate(to: parent)
    }

    private func refreshForInput() async {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let target = normalizedDirectory(value)
        if target == directory || FileListing.parentPath(of: target) == nil
            || value.hasSuffix("/") || value.hasSuffix("\\")
        {
            await load(target, filter: nil)
            return
        }
        let origin = directory
        let parent = FileListing.parentPath(of: target) ?? target
        let prefix = QuinjetPath.name(target)
        await load(parent, filter: prefix)
        guard path.trimmingCharacters(in: .whitespacesAndNewlines) == value else { return }
        let candidates = entries.indices.filter { navigable(entries[$0]) }
        if candidates.count == 1 { selectionIndex = candidates[0] }
        guard
            let exact = entries.first(where: {
                navigable($0) && $0.name.localizedCaseInsensitiveCompare(prefix) == .orderedSame
            })
        else { return }
        if !origin.isEmpty, origin != exact.path { history.append(origin) }
        path = exact.path
        selectionIndex = -1
        refreshTask = nil
        await load(exact.path, filter: nil)
    }

    private func load(_ target: String, filter: String?) async {
        loadToken += 1
        let token = loadToken
        loading = true
        errorMessage = nil
        do {
            let loaded = try await listDirectory(target)
            guard token == loadToken else { return }
            directory = target
            entries =
                loaded
                .filter { entry in
                    guard let filter, !filter.isEmpty else { return true }
                    return entry.name.range(
                        of: filter, options: [.caseInsensitive, .anchored]) != nil
                }
                .sorted(by: entryOrder)
            selectionIndex = -1
            loading = false
        } catch {
            guard token == loadToken else { return }
            directory = target
            entries = []
            selectionIndex = -1
            loading = false
            errorMessage = error.localizedDescription
        }
    }

    private func normalizedDirectory(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform: RemoteMachinePlatform =
            FileListing.isWindowsPath(homeDirectory)
            ? .windows : .linux
        let resolved = QuinjetPath.resolve(
            trimmed, homeDirectory: homeDirectory, platform: platform)
        guard resolved != "/", FileListing.parentPath(of: resolved) != nil else {
            return resolved
        }
        return resolved.hasSuffix("/") || resolved.hasSuffix("\\")
            ? String(resolved.dropLast()) : resolved
    }

    private func navigable(_ entry: RemoteFileEntry) -> Bool {
        entry.isDirectory || entry.kind == .symlink
    }

    private func entryOrder(_ lhs: RemoteFileEntry, _ rhs: RemoteFileEntry) -> Bool {
        if navigable(lhs) != navigable(rhs) { return navigable(lhs) }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

private enum QuinjetMachineError: LocalizedError {
    case connectionFailed(String)
    case connectionTimedOut
    case homeUnavailable

    var errorDescription: String? {
        switch self {
        case let .connectionFailed(message): return message
        case .connectionTimedOut: return "The machine did not connect in time."
        case .homeUnavailable: return "The machine home directory could not be resolved."
        }
    }
}
