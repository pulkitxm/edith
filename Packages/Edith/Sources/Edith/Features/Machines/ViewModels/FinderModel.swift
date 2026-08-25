import AppKit
import EdithKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class FinderModel {
    typealias DirectoryLoader =
        @MainActor @Sendable (String) async -> Result<
            [RemoteFileEntry], Error
        >
    typealias FreeSpaceLoader = @MainActor @Sendable (String) async -> Int64?

    var path: String
    var entries: [RemoteFileEntry] = []
    private(set) var loading = false
    var errorMessage: String?
    var statusMessage: String?
    var selection: Set<String> = [] {
        didSet { syncQuickLookToSelection() }
    }
    var renaming: String?
    var renameText = ""
    var quickLookPath: String?
    var freeSpaceKB: Int64?
    var searchQuery = ""
    var searchResults: [RemoteFileEntry]?
    var places: [FilePlaceSection] = []
    var infoTarget: RemoteFileEntry?
    var showSidebar = true
    var progress: FileOperationProgress?
    var pendingConflict: PendingConflict?
    var scrollTarget: String?
    static var clipboard: FileClipboard?

    struct PendingConflict: Identifiable {
        let id = UUID()
        var intent: DropIntent
        var destination: String
        var names: [String]
    }

    var viewModeRaw = FinderDefaults.viewMode {
        didSet { FinderDefaults.viewMode = viewModeRaw }
    }
    var sortKeyRaw = FinderDefaults.sortKey {
        didSet { FinderDefaults.sortKey = sortKeyRaw }
    }
    var sortAscending = FinderDefaults.sortAscending {
        didSet { FinderDefaults.sortAscending = sortAscending }
    }
    var showHidden = FinderDefaults.showHidden {
        didSet { FinderDefaults.showHidden = showHidden }
    }
    var iconSize = FinderDefaults.iconSize {
        didSet { FinderDefaults.iconSize = iconSize }
    }

    let session: MachineSession
    private var history: [String] = []
    private var future: [String] = []
    private var anchor: String?
    private var cursor: String?
    var gridColumns = 1
    private var typeBuffer = ""
    private var typeBufferAt = Date.distantPast
    private struct LoadRequest {
        let generation: Int
        let path: String
    }

    private struct LoadOutcome {
        let path: String
        let result: Result<[RemoteFileEntry], Error>
        let freeSpaceKB: Int64?
    }

    private var loadGeneration = 0
    private var loadWorkerGeneration = 0
    private var pendingLoad: LoadRequest?
    private var loadWorkerTask: Task<Void, Never>?
    private var activeLoadTask: Task<LoadOutcome?, Never>?
    private var flashToken = 0
    private var searchToken = 0
    private var searchTask: Task<Void, Never>?
    private let localSearch: @Sendable (String, String) async -> [RemoteFileEntry]
    private let directoryLoader: DirectoryLoader
    private let freeSpaceLoader: FreeSpaceLoader
    private var folderSizes: [String: Int64] = [:]
    private var folderCounts: [String: Int] = [:]
    private var resolvedHome: String?
    private var undoStack: [FinderUndoStep] = []

    init(
        session: MachineSession, path: String? = nil,
        localSearch: @escaping @Sendable (String, String) async -> [RemoteFileEntry] = {
            root, query in
            await Task.detached(priority: .userInitiated) {
                MachineSession.searchLocalFiles(root: root, query: query)
            }.value
        }, directoryLoader: DirectoryLoader? = nil, freeSpaceLoader: FreeSpaceLoader? = nil
    ) {
        self.session = session
        self.localSearch = localSearch
        self.directoryLoader = directoryLoader ?? { await session.listFiles(path: $0) }
        self.freeSpaceLoader =
            freeSpaceLoader ?? { path in
                if session.isLocal {
                    let values = try? URL(fileURLWithPath: path).resourceValues(
                        forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    return (values?.volumeAvailableCapacityForImportantUsage).map { $0 / 1024 }
                }
                let result = await session.runCommand(
                    FileOperations.freeSpaceCommand(path: path), timeout: 20)
                guard case let .success(output) = result else { return nil }
                return Int64(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        self.path =
            path
            ?? (session.isLocal ? FileManager.default.homeDirectoryForCurrentUser.path : "~")
    }

    var viewMode: FileViewMode {
        get { FileViewMode(rawValue: viewModeRaw) ?? .list }
        set { viewModeRaw = newValue.rawValue }
    }

    var sortKey: FileSortKey {
        get { FileSortKey(rawValue: sortKeyRaw) ?? .name }
        set { sortKeyRaw = newValue.rawValue }
    }

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !future.isEmpty }
    var canGoUp: Bool { FileListing.parentPath(of: path) != nil }

    var visibleEntries: [RemoteFileEntry] {
        if let searchResults { return searchResults }
        let base = showHidden ? entries : entries.filter { !$0.isHidden }
        return FileSorting.sort(base, by: sortKey, ascending: sortAscending)
    }

    var selectedEntries: [RemoteFileEntry] {
        visibleEntries.filter { selection.contains($0.path) }
    }

    var canRevealSelection: Bool {
        if session.isLocal { return !selectedEntries.isEmpty }
        return selectedEntries.contains { !$0.isDirectory }
    }

    var statusLine: String {
        let total = visibleEntries.count
        var text = "\(total) item\(total == 1 ? "" : "s")"
        if selection.count == 1, let entry = selectedEntries.first {
            text += ", \(entry.name) selected"
        } else if selection.count > 1 {
            let bytes = selectedEntries.reduce(Int64(0)) { $0 + $1.sizeBytes }
            text += ", \(selection.count) selected (\(ByteFormatter.string(bytes)))"
        }
        if let freeSpaceKB {
            text += "  ·  \(ByteFormatter.string(freeSpaceKB * 1024)) available"
        }
        return text
    }

    func connectIfNeeded() {
        guard !session.isLocal else { return }
        if case .disconnected = session.state { session.start() }
    }

    func waitForConnection(timeout: TimeInterval = 30) async {
        guard !session.isLocal else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if session.state.isConnected { return }
            if case .failed = session.state { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    func loadPlaces() async {
        if session.isLocal {
            let volumes =
                FileManager.default.mountedVolumeURLs(
                    includingResourceValuesForKeys: [.volumeIsBrowsableKey],
                    options: [.skipHiddenVolumes]) ?? []
            let external = volumes.filter { $0.path != "/" }
            places = FilePlaces.localSections(volumes: external)
            return
        }
        let result = await session.runCommand(FilePlaces.homeDirectoryCommand(), timeout: 20)
        let home =
            (try? result.get())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "~"
        places = FilePlaces.remoteSections(home: home.isEmpty ? "~" : home)
    }

    func copySelection(operation: FileClipboardOperation) {
        let paths = selectedEntries.map(\.path)
        guard !paths.isEmpty else { return }
        Self.clipboard = FileClipboard(
            paths: paths, machineID: session.machine.id, operation: operation)
        flash(
            "\(operation == .copy ? "Copied" : "Cut") \(paths.count) item"
                + (paths.count == 1 ? "" : "s"))
    }

    func paste() async {
        guard let clipboard = Self.clipboard else { return }
        guard clipboard.machineID == session.machine.id else {
            errorMessage = "Copying between machines is not supported yet."
            return
        }
        let isCopy = clipboard.operation == .copy
        let alreadyHere = clipboard.paths.filter { FileListing.parentPath(of: $0) == path }
        let fromElsewhere = clipboard.paths.filter { FileListing.parentPath(of: $0) != path }
        guard isCopy || !fromElsewhere.isEmpty else {
            errorMessage = "Those items are already here."
            return
        }
        if isCopy, !alreadyHere.isEmpty {
            await duplicate(paths: alreadyHere)
        }
        if !fromElsewhere.isEmpty {
            await perform(
                intent: isCopy
                    ? .copyWithinMachine(fromElsewhere) : .moveWithinMachine(fromElsewhere),
                destination: path)
        }
        if !isCopy, errorMessage == nil { Self.clipboard = nil }
    }

    func showInfo() {
        infoTarget = selectedEntries.first
        guard let target = infoTarget, target.isDirectory else { return }
        Task { await measure(target) }
    }

    func infoSummary(for entry: RemoteFileEntry) -> FileInfoSummary {
        guard entry.isDirectory else { return FileInfoSummary(entry: entry) }
        return FileInfoSummary(entry: entry, sizeOverride: folderSummary(for: entry))
    }

    func setViewMode(_ mode: FileViewMode) {
        viewMode = mode
    }

    func toggleHidden() {
        showHidden.toggle()
    }

    func load() async {
        await scheduleLoad().value
    }

    private func scheduleLoad() -> Task<Void, Never> {
        loadGeneration += 1
        pendingLoad = LoadRequest(generation: loadGeneration, path: path)
        activeLoadTask?.cancel()
        loading = true
        errorMessage = nil
        if let loadWorkerTask { return loadWorkerTask }
        loadWorkerGeneration += 1
        let workerGeneration = loadWorkerGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainLoads(workerGeneration: workerGeneration)
        }
        loadWorkerTask = task
        return task
    }

    private func drainLoads(workerGeneration: Int) async {
        while !Task.isCancelled, let request = pendingLoad {
            pendingLoad = nil
            let operation = Task { [weak self] in
                await self?.loadDirectory(request.path)
            }
            activeLoadTask = operation
            let outcome = await operation.value
            guard workerGeneration == loadWorkerGeneration else { return }
            activeLoadTask = nil
            guard !operation.isCancelled, request.generation == loadGeneration, let outcome else {
                continue
            }
            publish(outcome, requestedPath: request.path)
        }
        guard workerGeneration == loadWorkerGeneration else { return }
        loadWorkerTask = nil
        activeLoadTask = nil
        loading = false
    }

    private func loadDirectory(_ requestedPath: String) async -> LoadOutcome? {
        var resolvedPath = requestedPath
        if !session.isLocal, requestedPath == "~" || requestedPath.isEmpty {
            let result = await session.runCommand(FilePlaces.homeDirectoryCommand(), timeout: 20)
            guard !Task.isCancelled else { return nil }
            if case let .success(output) = result {
                let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if home.hasPrefix("/") { resolvedPath = home }
            }
        }
        let result = await directoryLoader(resolvedPath)
        guard !Task.isCancelled else { return nil }
        let freeSpaceKB = await freeSpaceLoader(resolvedPath)
        guard !Task.isCancelled else { return nil }
        return LoadOutcome(path: resolvedPath, result: result, freeSpaceKB: freeSpaceKB)
    }

    private func publish(_ outcome: LoadOutcome, requestedPath: String) {
        if path == requestedPath, outcome.path != requestedPath {
            resolvedHome = outcome.path
            path = outcome.path
        }
        guard path == outcome.path else { return }
        loading = false
        freeSpaceKB = outcome.freeSpaceKB
        switch outcome.result {
        case let .success(items):
            entries = items
            selection = selection.filter { path in items.contains { $0.path == path } }
        case let .failure(failure):
            entries = []
            errorMessage = failure.localizedDescription
        }
    }

    func stopLoading() {
        loadGeneration += 1
        loadWorkerGeneration += 1
        pendingLoad = nil
        activeLoadTask?.cancel()
        activeLoadTask = nil
        loadWorkerTask?.cancel()
        loadWorkerTask = nil
        loading = false
    }

    func navigate(to newPath: String, recordHistory: Bool = true) {
        let target = expandingHome(newPath)
        guard target != path else { return }
        invalidateSearch()
        if recordHistory {
            history.append(path)
            future.removeAll()
        }
        path = target
        entries = []
        selection = []
        anchor = nil
        searchResults = nil
        searchQuery = ""
        _ = scheduleLoad()
    }

    private func expandingHome(_ candidate: String) -> String {
        guard candidate == "~" || candidate.hasPrefix("~/") else { return candidate }
        guard let home = resolvedHome else { return candidate }
        if candidate == "~" { return home }
        return FileListing.join(parent: home, name: String(candidate.dropFirst(2)))
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
        let target =
            session.isLocal
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : (places.first?.places.first?.path ?? "~")
        navigate(to: target)
    }

    func refresh() {
        _ = scheduleLoad()
    }

    func open(_ entry: RemoteFileEntry) {
        if entry.isDirectory || entry.kind == .symlink {
            navigate(to: entry.path)
            return
        }
        if session.isLocal {
            RemoteFileOperationExecution.present(
                [URL(fileURLWithPath: entry.path)], action: .open
            ) { urls, _ in NSWorkspace.shared.open(urls[0]) }
            return
        }
        Task { await openRemote(entry) }
    }

    private func openRemote(_ entry: RemoteFileEntry) async {
        statusMessage = "Opening \(entry.name)…"
        do {
            let destination = try await RemoteFileOperationExecution.materialize(
                entry, machineID: session.machine.id, isLocal: false
            ) { remotePath, localURL in
                guard let connection = session.connectionRef else {
                    throw FinderTransferError.notConnected
                }
                try await connection.download(remotePath: remotePath, to: localURL)
            }
            RemoteFileOperationExecution.present([destination], action: .open) { urls, _ in
                NSWorkspace.shared.open(urls[0])
            }
            flash("Opened \(entry.name)")
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    func openSelection() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        if targets.count == 1 || targets.contains(where: \.isDirectory) {
            guard let first = targets.first else { return }
            open(first)
            return
        }
        for entry in targets { open(entry) }
    }

    func toggleQuickLook() {
        if quickLookPath != nil {
            quickLookPath = nil
        } else {
            quickLookPath = quickLookTarget
        }
    }

    private var quickLookTarget: String? {
        let ordered = visibleEntries.filter { selection.contains($0.path) }
        return ordered.first?.path ?? visibleEntries.first?.path
    }

    private func syncQuickLookToSelection() {
        guard quickLookPath != nil, let target = quickLookTarget, target != quickLookPath else {
            return
        }
        quickLookPath = target
    }

    func measure(_ entry: RemoteFileEntry) async {
        guard entry.isDirectory, folderSizes[entry.path] == nil else { return }
        folderSizes[entry.path] = -1
        if session.isLocal {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: entry.path).count)
            folderCounts[entry.path] = count ?? 0
        }
        let result = await MachineFileOperationExecution.info(path: entry.path) {
            [session] command, timeout in
            await session.runCommand(command, timeout: timeout)
        }
        switch result {
        case let .success(bytes): folderSizes[entry.path] = bytes / 1024
        case .failure: folderSizes[entry.path] = 0
        }
    }

    func folderSummary(for entry: RemoteFileEntry) -> String {
        guard let kilobytes = folderSizes[entry.path], kilobytes >= 0 else {
            return "Calculating size…"
        }
        var text = ByteFormatter.string(kilobytes * 1024)
        if let count = folderCounts[entry.path] {
            text += ", \(count) item\(count == 1 ? "" : "s")"
        }
        return text
    }

    func renameSelection() {
        guard let entry = selectedEntries.first else { return }
        beginRename(entry)
    }

    func click(_ entry: RemoteFileEntry, modifiers: EventModifiers) {
        if modifiers.contains(.shift) {
            selection = FileSelectionMath.rangeSelection(
                in: visibleEntries, from: anchor, to: entry.path)
        } else if modifiers.contains(.command) {
            selection = FileSelectionMath.toggled(selection, path: entry.path)
            anchor = entry.path
            cursor = entry.path
        } else {
            selection = [entry.path]
            anchor = entry.path
            cursor = entry.path
        }
    }

    func selectAll() {
        let items = visibleEntries
        selection = Set(items.map(\.path))
        anchor = items.first?.path
        cursor = items.last?.path
    }

    func invertSelection() {
        let items = visibleEntries
        selection = Set(items.map(\.path).filter { !selection.contains($0) })
        anchor = selection.isEmpty ? nil : items.first { selection.contains($0.path) }?.path
        cursor = anchor
    }

    func moveSelection(by offset: Int, extend: Bool) {
        let items = visibleEntries
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex { $0.path == (cursor ?? selection.first) } ?? -1
        let nextIndex = max(0, min(items.count - 1, currentIndex + offset))
        let target = items[nextIndex]
        cursor = target.path
        if extend {
            if anchor == nil { anchor = items[max(currentIndex, 0)].path }
            selection = FileSelectionMath.rangeSelection(
                in: items, from: anchor, to: target.path)
        } else {
            selection = [target.path]
            anchor = target.path
        }
        reveal(target.path)
        if quickLookPath != nil { quickLookPath = target.path }
    }

    func moveSelection(_ direction: FinderMoveDirection, extend: Bool) {
        let stride = viewMode == .icon ? max(gridColumns, 1) : 1
        return switch direction {
        case .up: moveSelection(by: viewMode == .icon ? -stride : -1, extend: extend)
        case .down: moveSelection(by: viewMode == .icon ? stride : 1, extend: extend)
        case .left: moveSelection(by: viewMode == .icon ? -1 : 0, extend: extend)
        case .right: moveSelection(by: viewMode == .icon ? 1 : 0, extend: extend)
        }
    }

    func typeSelect(_ characters: String) {
        let now = Date()
        if now.timeIntervalSince(typeBufferAt) > 0.75 { typeBuffer = "" }
        typeBufferAt = now
        typeBuffer += characters.lowercased()
        guard
            let match = FileSelectionMath.typeSelectMatch(
                in: visibleEntries, prefix: typeBuffer, after: anchor)
        else { return }
        selection = [match]
        reveal(match)
        anchor = match
    }

    func beginRename(_ entry: RemoteFileEntry) {
        renaming = entry.path
        renameText = entry.name
    }

    func reveal(_ path: String?) {
        guard let path else { return }
        scrollTarget = path
    }

    var canUndo: Bool { !undoStack.isEmpty }

    var undoTitle: String? {
        guard let last = undoStack.last else { return nil }
        return "Undo \(last.label)"
    }

    func recordUndo(_ step: FinderUndoStep) {
        undoStack.append(step)
        if undoStack.count > 20 { undoStack.removeFirst(undoStack.count - 20) }
    }

    func undoLastOperation() async {
        guard let step = undoStack.popLast() else {
            flash("Nothing to undo")
            return
        }
        let result = await MachineFileOperationExecution.undo(step) {
            [session] command, timeout in
            await session.runCommand(command, timeout: timeout)
        }
        if case let .failure(error) = result {
            undoStack.append(step)
            errorMessage = error.localizedDescription
        }
        await load()
        if case let .success(restored) = result {
            selection = Set(restored)
            flash("Undid \(step.label)")
        }
    }

    func focusContext(on entry: RemoteFileEntry) {
        guard !selection.contains(entry.path) else { return }
        selection = [entry.path]
    }

    func commitRename() async {
        guard let renaming else { return }
        let pool = searchResults ?? entries
        guard let entry = pool.first(where: { $0.path == renaming }) else {
            self.renaming = nil
            return
        }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RenameSelection.isValid(trimmed) else {
            errorMessage = "That name cannot be used."
            return
        }
        guard trimmed != entry.name else {
            self.renaming = nil
            return
        }
        let parent = FileListing.parentPath(of: entry.path) ?? path
        let siblings = entries.filter { $0.path != entry.path }
        let sameNameDifferentCase =
            NameFolding.key(trimmed, caseInsensitive: true)
            == NameFolding.key(entry.name, caseInsensitive: true)
        if !sameNameDifferentCase,
            !NameConflicts.conflicting(names: [trimmed], existing: siblings).isEmpty
        {
            errorMessage = "An item named \(trimmed) already exists here."
            return
        }
        self.renaming = nil
        let target = FileListing.join(parent: parent, name: trimmed)
        let result = await MachineFileOperationExecution.rename(
            path: entry.path, destination: target, viaTemporary: sameNameDifferentCase
        ) { [session] command, timeout in
            await session.runCommand(command, timeout: timeout)
        }
        await load()
        switch result {
        case .success:
            recordUndo(
                FinderUndoStep(
                    label: "Rename", moves: [FinderUndoStep.Move(from: entry.path, to: target)]))
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
        if case .success = result {
            selection = [target]
            reveal(target)
        }
    }

    func newFolder() async {
        let name = FileOperations.newFolderName(existing: entries)
        let target = FileListing.join(parent: path, name: name)
        if case let .failure(error) = await session.createDirectory(path: target) {
            errorMessage = error.localizedDescription
            return
        }
        await load()
        if let created = entries.first(where: { $0.path == target }) {
            selection = [target]
            reveal(target)
            beginRename(created)
        }
    }

    func duplicateSelection() async {
        await duplicate(paths: selectedEntries.map(\.path))
    }

    func duplicate(paths: [String]) async {
        guard !paths.isEmpty else { return }
        var taken = entries
        for source in paths {
            let name = FileOperations.duplicateName(
                of: (source as NSString).lastPathComponent, existing: taken)
            let target = FileListing.join(parent: path, name: name)
            taken.append(
                RemoteFileEntry(name: name, path: target, kind: .file, sizeBytes: 0))
            let result = await MachineFileOperationExecution.duplicate(
                path: source, destination: target
            ) { [session] command, timeout in
                await session.runCommand(command, timeout: timeout)
            }
            if case let .failure(error) = result {
                errorMessage = error.localizedDescription
                break
            }
        }
        await load()
    }

    func trashSelection(permanently: Bool) async {
        let paths = selectedEntries.map(\.path)
        guard !paths.isEmpty else { return }
        let plan = MachineFileRemovalPlan(paths: paths, permanently: permanently)
        let nativeTrash: MachineFileOperationExecution.Trash? =
            session.isLocal && !permanently
            ? { paths in
                do {
                    for path in paths {
                        try FileManager.default.trashItem(
                            at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            } : nil
        let result = await MachineFileOperationExecution.remove(
            plan, confirmed: true, trash: nativeTrash
        ) { [session] command, timeout in
            await session.runCommand(command, timeout: timeout)
        }
        switch result {
        case .success:
            selection = []
            await load()
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    func copyPaths() {
        let paths = selectedEntries.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        flash("Copied \(paths.count) path\(paths.count == 1 ? "" : "s")")
    }

    func flash(_ message: String) {
        statusMessage = message
        flashToken += 1
        let token = flashToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, token == flashToken else { return }
            statusMessage = nil
        }
    }

    func revealInFinder() async {
        errorMessage = nil
        let projection = await FinderRevealProjection.make(
            entries: selectedEntries, isLocal: session.isLocal)
        guard !Task.isCancelled else { return }
        let targets = projection.targets
        guard !targets.isEmpty else { return }
        do {
            let urls: [URL]
            if let localURLs = projection.localURLs {
                urls = localURLs
            } else {
                guard let connection = session.connectionRef else {
                    throw FinderTransferError.notConnected
                }
                var materialized: [URL] = []
                for entry in targets {
                    let destination = try await RemoteFileOperationExecution.materialize(
                        entry, machineID: session.machine.id, isLocal: false
                    ) { remotePath, localURL in
                        try await connection.download(remotePath: remotePath, to: localURL)
                    }
                    materialized.append(destination)
                }
                urls = materialized
            }
            let presented = RemoteFileOperationExecution.present(urls, action: .reveal) {
                urls, _ in
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                return true
            }
            guard presented else {
                throw FinderTransferError.presentationUnavailable
            }
            flash("Revealed \(urls.count) item\(urls.count == 1 ? "" : "s")")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download(to destination: URL) async {
        guard let connection = session.connectionRef else { return }
        for entry in selectedEntries where !entry.isDirectory {
            statusMessage = "Downloading \(entry.name)…"
            let target = destination.appendingPathComponent(entry.name)
            do {
                try await RemoteFileOperationExecution.download(
                    remotePath: entry.path, to: target
                ) { remotePath, localURL in
                    try await connection.download(remotePath: remotePath, to: localURL)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        flash("Download finished")
    }

    func upload(_ urls: [URL]) async {
        guard let connection = session.connectionRef else {
            for url in urls {
                let target = FileListing.join(parent: path, name: url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: target))
            }
            await load()
            return
        }
        for url in urls {
            statusMessage = "Uploading \(url.lastPathComponent)…"
            let target = FileListing.join(parent: path, name: url.lastPathComponent)
            do {
                try await connection.upload(localURL: url, toRemotePath: target)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        flash("Upload finished")
        await load()
    }

    func searchQueryChanged() {
        invalidateSearch()
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = nil
            return
        }
        searchResults = entries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        let token = searchToken
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, token == searchToken, searchQuery == trimmed || !searchQuery.isEmpty
            else { return }
            await runDeepSearch(trimmed, token: token)
        }
    }

    private func runDeepSearch(_ query: String, token: Int) async {
        let shallow = entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let localAdapter: MachineFileOperationExecution.LocalSearch? =
            session.isLocal
            ? { [localSearch] root, query, limit in
                let entries = await localSearch(root, query)
                return .success(
                    entries.prefix(limit).map {
                        MachineFileSearchItem(path: $0.path, kind: $0.kind)
                    })
            } : nil
        let result = await MachineFileOperationExecution.search(
            path: path, query: query, localSearch: localAdapter
        ) { [session] command, timeout in
            await session.runCommand(command, timeout: timeout)
        }
        guard token == searchToken, case let .success(items) = result else { return }
        var seen = Set(shallow.map { FilePathKey.canonical($0.path) })
        var combined = shallow
        for item in items {
            let full = item.path
            guard !full.isEmpty, seen.insert(FilePathKey.canonical(full)).inserted else { continue }
            let kind = item.kind ?? entries.first { $0.path == full }?.kind ?? .file
            combined.append(
                RemoteFileEntry(
                    name: (full as NSString).lastPathComponent, path: full,
                    kind: kind, sizeBytes: 0))
        }
        searchResults = combined
    }

    private func invalidateSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchToken += 1
    }

    func runSearch() async {
        searchQueryChanged()
        await searchTask?.value
    }

    private func run(_ command: String, reload: Bool) async {
        let result = await session.runCommand(command, timeout: 120)
        var failureMessage: String?
        if case let .failure(failure) = result {
            failureMessage = failure.localizedDescription
        }
        if reload { await load() }
        if let failureMessage { errorMessage = failureMessage }
    }

    func dragPayload() -> MachineItemsPayload {
        MachineItemsPayload(
            machineID: session.machine.id, paths: selectedEntries.map(\.path),
            isLocal: session.isLocal)
    }

    func handleDrop(
        providers: [NSItemProvider], destination: String, optionHeld: Bool
    ) async {
        var payload: MachineItemsPayload?
        var localPaths: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(MachineItemsPayload.typeIdentifier) {
                if let data = await provider.loadDataSafely(
                    forTypeIdentifier: MachineItemsPayload.typeIdentifier)
                {
                    payload = MachineItemsPayload.decode(data)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let data = await provider.loadDataSafely(
                    forTypeIdentifier: UTType.fileURL.identifier),
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                {
                    localPaths.append(url.path)
                }
            }
        }
        guard
            let intent = DropResolver.intent(
                payload: payload, fileURLPaths: localPaths,
                destinationMachine: session.machine.id, optionHeld: optionHeld)
        else { return }
        await perform(intent: intent, destination: destination)
    }

    private func destinationEntries(_ destination: String) async -> [RemoteFileEntry] {
        if destination == path { return entries }
        if case let .success(items) = await session.listFiles(path: destination) { return items }
        return []
    }

    func perform(intent: DropIntent, destination: String) async {
        guard DropResolver.isDropAllowed(paths: intent.paths, destination: destination) else {
            return
        }
        let names = intent.paths.map { ($0 as NSString).lastPathComponent }
        let existing = await destinationEntries(destination)
        let clashes = NameConflicts.conflicting(names: names, existing: existing)
        if !clashes.isEmpty {
            pendingConflict = PendingConflict(
                intent: intent, destination: destination, names: clashes)
            return
        }
        await commit(intent: intent, destination: destination, resolutions: [:])
    }

    func commit(
        intent: DropIntent, destination: String,
        resolutions: [String: NameConflictResolution]
    ) async {
        switch intent {
        case .moveWithinMachine, .copyWithinMachine:
            let existing = await destinationEntries(destination)
            guard
                let command = NameConflicts.command(
                    intent: intent, destination: destination, resolutions: resolutions,
                    existing: existing)
            else { return }
            progress = FileOperationProgress(
                title: intent.isMove ? "Moving" : "Copying", total: intent.paths.count)
            await run(command, reload: true)
            progress = nil
            if intent.isMove, errorMessage == nil {
                recordUndo(
                    FinderUndoStep(
                        label: "Move",
                        moves: intent.paths.map {
                            FinderUndoStep.Move(
                                from: $0,
                                to: FileListing.join(
                                    parent: destination,
                                    name: ($0 as NSString).lastPathComponent))
                        }))
            }
        case let .uploadLocalFiles(paths):
            await uploadPaths(paths.map { URL(fileURLWithPath: $0) }, into: destination)
        case let .transferBetweenMachines(from, paths):
            await transfer(paths: paths, fromMachine: from, into: destination)
        }
    }

    private func transfer(paths: [String], fromMachine: UUID, into destination: String) async {
        guard let source = MachinesModel.shared.sessions[fromMachine] else { return }
        progress = FileOperationProgress(title: "Transferring", total: paths.count)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var completed = 0
        var failures: [String] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let local = staging.appendingPathComponent(name)
            do {
                if source.isLocal {
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: local)
                } else if let connection = source.connectionRef {
                    try await connection.download(remotePath: path, to: local)
                } else {
                    throw TransferFailure.noConnection(source.machine.name)
                }
                if session.isLocal {
                    try FileManager.default.moveItem(
                        at: local,
                        to: URL(fileURLWithPath: FileListing.join(parent: destination, name: name)))
                } else if let connection = session.connectionRef {
                    try await connection.upload(
                        localURL: local,
                        toRemotePath: FileListing.join(parent: destination, name: name))
                } else {
                    throw TransferFailure.noConnection(session.machine.name)
                }
                completed += 1
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
            progress = FileOperationProgress(
                title: "Transferring", completed: completed, total: paths.count)
        }
        try? FileManager.default.removeItem(at: staging)
        progress = nil
        if failures.isEmpty {
            flash("Transferred \(completed) item\(completed == 1 ? "" : "s")")
        } else {
            errorMessage =
                failures.count == 1
                ? failures[0]
                : "\(failures.count) of \(paths.count) items failed. \(failures[0])"
        }
        await load()
    }

    enum TransferFailure: LocalizedError {
        case noConnection(String)

        var errorDescription: String? {
            switch self {
            case let .noConnection(name): return "\(name) is not connected."
            }
        }
    }

    private func uploadPaths(_ urls: [URL], into destination: String) async {
        guard !urls.isEmpty else { return }
        progress = FileOperationProgress(title: "Uploading", total: urls.count)
        if session.isLocal {
            for url in urls {
                let target = FileListing.join(
                    parent: destination, name: url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: target))
            }
        } else if let connection = session.connectionRef {
            var completed = 0
            for url in urls {
                let target = FileListing.join(
                    parent: destination, name: url.lastPathComponent)
                try? await connection.upload(localURL: url, toRemotePath: target)
                completed += 1
                progress = FileOperationProgress(
                    title: "Uploading", completed: completed, total: urls.count)
            }
        }
        progress = nil
        await load()
    }

    func moveSelection(into destination: String) async {
        let paths = selectedEntries.map(\.path)
        guard !paths.isEmpty else { return }
        await perform(intent: .moveWithinMachine(paths), destination: destination)
    }

    func dragProvider(for entry: RemoteFileEntry) -> NSItemProvider {
        let provider = itemProvider(for: entry)
        if let data = dragPayload().encoded() {
            provider.registerDataRepresentation(
                forTypeIdentifier: MachineItemsPayload.typeIdentifier, visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    func itemProvider(for entry: RemoteFileEntry) -> NSItemProvider {
        if session.isLocal {
            return NSItemProvider(contentsOf: URL(fileURLWithPath: entry.path))
                ?? NSItemProvider()
        }
        let provider = NSItemProvider()
        provider.suggestedName = entry.name
        let type = UTType(filenameExtension: entry.fileExtension) ?? .data
        let contentType = type.conforms(to: .data) ? type : .data
        let connection = session.connectionRef
        let remotePath = entry.path
        let name = entry.name
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier, fileOptions: [], visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: max(1, entry.sizeBytes))
            let task = Task.detached {
                guard let connection else {
                    completion(nil, false, FinderTransferError.notConnected)
                    return
                }
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(
                    at: destination, withIntermediateDirectories: true)
                let fileURL = destination.appendingPathComponent(name)
                do {
                    try await RemoteFileOperationExecution.download(
                        remotePath: remotePath, to: fileURL
                    ) { remotePath, localURL in
                        try await connection.download(
                            remotePath: remotePath, to: localURL
                        ) { sent in progress.completedUnitCount = sent }
                    }
                    completion(fileURL, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}

enum FinderTransferError: LocalizedError {
    case notConnected
    case presentationUnavailable

    var errorDescription: String? {
        switch self {
        case .notConnected: "The machine is not connected."
        case .presentationUnavailable: "Finder is unavailable."
        }
    }
}

private struct FinderRevealProjection: Sendable {
    let targets: [RemoteFileEntry]
    let localURLs: [URL]?

    static func make(entries: [RemoteFileEntry], isLocal: Bool) async -> FinderRevealProjection {
        await Task.detached(priority: .userInitiated) {
            let targets = isLocal ? entries : entries.filter { !$0.isDirectory }
            return FinderRevealProjection(
                targets: targets,
                localURLs: isLocal ? targets.map { URL(fileURLWithPath: $0.path) } : nil)
        }.value
    }
}

extension DropIntent {
    var isMove: Bool {
        if case .moveWithinMachine = self { return true }
        return false
    }
}

extension NSItemProvider {
    func loadDataSafely(forTypeIdentifier identifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
