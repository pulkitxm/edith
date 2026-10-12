import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation

@MainActor @Observable
final class BlitzTreeModel {
    private(set) var report: BlitzTreeReport?
    let loading = ContentLoad()
    var scanning: Bool { loading.isRunning }
    private(set) var removing = false
    private(set) var scannedEntries: UInt64 = 0
    private(set) var root: String?
    private(set) var history: [String] = []
    private(set) var error: String?
    private(set) var stopped = false
    private(set) var previewToken = UUID()
    private var engineClient: ExtensionEngineClient?
    private var suspending = false
    private var pickerTask: Task<Void, Never>?
    private var remoteTask: Task<Void, Never>?
    private var remoteRevision = 0
    private let client: BlitzTreeClient
    private let remove: @Sendable (BlitzTreeReport.Entry, String, Progress) async throws -> Void
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var current: (id: UUID, cancellation: Progress)?
    @ObservationIgnored private var folderPicker: NSOpenPanel?
    var ownedOperationCount: Int { tasks.count }

    init(
        client: BlitzTreeClient = .live,
        remove: @escaping @Sendable (BlitzTreeReport.Entry, String, Progress) async throws -> Void =
            { entry, root, cancellation in
                try await BlockingWork.perform {
                    try BlitzTreeActions.trash(
                        entry, root: root, isCancelled: { cancellation.isCancelled })
                }
            }
    ) {
        self.client = client
        self.remove = remove
    }

    convenience init(engineClient: ExtensionEngineClient) {
        self.init()
        self.engineClient = engineClient
    }

    func reveal(_ path: String) {
        guard !stopped, !suspending else { return }
        if engineClient != nil {
            guard let payload = try? JSONEncoder().encode(["path": path]) else { return }
            remote("blitztree.ui.reveal", payload: payload); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    func uiSnapshot() -> BlitzTreeUISnapshot {
        .init(
            report: report, root: root, history: history, previewToken: previewToken,
            scanning: scanning, removing: removing, scannedEntries: scannedEntries, error: error)
    }

    func refreshRemote() async {
        guard let task = track({ [self] in await refreshRemoteWork() }) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func refreshRemoteWork() async {
        guard let engineClient, !stopped, !suspending else { return }
        let revision = remoteRevision
        do {
            let data = try await engineClient.invoke("blitztree.ui.snapshot")
            guard !stopped, !suspending, !Task.isCancelled, revision == remoteRevision else {
                return
            }
            applyRemote(try JSONDecoder().decode(BlitzTreeUISnapshot.self, from: data))
        } catch is CancellationError {} catch {
            if !stopped, !suspending { self.error = error.localizedDescription }
        }
    }

    private func applyRemote(_ value: BlitzTreeUISnapshot) {
        report = value.report; root = value.root; history = value.history
        previewToken = value.previewToken; removing = value.removing;
        scannedEntries = value.scannedEntries; error = value.error
        if value.scanning {
            if !loading.isRunning { _ = loading.begin() }
        } else if value.report != nil {
            loading.setContent()
        } else if let error = value.error {
            loading.fail(loading.begin(), message: error)
        } else {
            loading.cancel()
        }
    }

    private func remote(_ command: String, payload: Data = Data("{}".utf8)) {
        guard let engineClient, !stopped, !suspending else { return }
        remoteTask?.cancel(); remoteRevision += 1
        let revision = remoteRevision
        remoteTask = track { [self] in
            defer { if revision == remoteRevision { remoteTask = nil } }
            do {
                _ = try await engineClient.invoke(command, payload: payload, timeout: 30)
                guard !stopped, !suspending, !Task.isCancelled, revision == remoteRevision else {
                    return
                }
                await refreshRemote()
            } catch is CancellationError {} catch {
                guard !stopped, !suspending, revision == remoteRevision else { return }
                self.error = error.localizedDescription; loading.fail(loading.begin(), error: error)
            }
        }
    }

    func scan(_ path: String, remember: Bool = true) {
        guard !stopped, !suspending, !removing else { return }
        if engineClient != nil {
            guard path.hasPrefix("/"), !path.utf8.contains(0),
                let payload = try? JSONEncoder().encode(["path": path])
            else { return }
            remote("blitztree.ui.scan", payload: payload)
            return
        }
        cancel()
        if remember, let root, root != path { history.append(root) }
        if history.count > 100 { history.removeFirst(history.count - 100) }
        root = path
        previewToken = UUID()
        if report?.root != path { report = nil }
        error = nil
        scannedEntries = 0
        let generation = loading.begin(preservingContent: report != nil)
        launch { [self] _ in
            do {
                let updates = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let result = try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor [self] in
                        for await count in updates.stream {
                            guard !stopped, !suspending, loading.isCurrent(generation) else {
                                return
                            }
                            scannedEntries = count
                        }
                    }
                    defer { updates.continuation.finish() }
                    return try await client.scan(root: path) { count in
                        updates.continuation.yield(count)
                    }
                }
                guard !stopped, !suspending, loading.isCurrent(generation) else { return }
                report = result
                root = result.root
                previewToken = UUID()
                loading.complete(generation)
            } catch {
                guard !stopped, !suspending, loading.owns(generation), !Task.isCancelled else {
                    return
                }
                loading.fail(generation, error: error)
                self.error = loading.errorMessage
            }
        }
    }

    func back() {
        if engineClient != nil { remote("blitztree.ui.back"); return }
        guard !stopped, !suspending, !removing, let previous = history.popLast() else { return }
        scan(previous, remember: false)
    }

    func cancel() {
        if engineClient != nil, !stopped, !suspending { remote("blitztree.cancel"); return }
        loading.cancel()
        if let current {
            current.cancellation.cancel()
            tasks[current.id]?.cancel()
        }
        folderPicker?.cancel(nil)
        folderPicker?.orderOut(nil)
    }

    func trash(_ entry: BlitzTreeReport.Entry) {
        if engineClient != nil {
            guard
                let payload = try? JSONEncoder().encode(
                    BlitzTreeUITrash(path: entry.path, confirmed: true, previewToken: previewToken))
            else { return }
            remote("blitztree.ui.trash", payload: payload)
            return
        }
        guard !stopped, !suspending, !scanning, !removing, let report,
            entries(in: report).contains(where: {
                $0.path == entry.path && $0.device == entry.device && $0.inode == entry.inode
            })
        else { return }
        removing = true
        error = nil
        let generation = loading.begin()
        launch { [self] cancellation in
            defer { removing = false }
            do {
                try await remove(entry, report.root, cancellation)
                guard !stopped, !suspending, loading.isCurrent(generation) else { return }
                removing = false
                loading.complete(generation)
                scan(report.root, remember: false)
            } catch {
                guard !stopped, !suspending, loading.owns(generation), !Task.isCancelled else {
                    return
                }
                loading.fail(generation, error: error)
                self.error = error.localizedDescription
            }
        }
    }

    func entries(in report: BlitzTreeReport) -> [BlitzTreeReport.Entry] {
        report.report.candidates + report.report.inventory.largestChildren
            + report.report.inventory.largestDirectories + report.report.inventory.largestFiles
    }

    private func launch(_ action: @escaping @MainActor (Progress) async -> Void) {
        guard !stopped, !suspending, tasks.count < 64 else { return }
        let id = UUID()
        let cancellation = Progress(totalUnitCount: 0)
        current = (id, cancellation)
        tasks[id] = Task {
            defer {
                tasks[id] = nil
                if current?.id == id { current = nil }
            }
            await withTaskCancellationHandler {
                await action(cancellation)
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    var commandWork: Task<Void, Never>? { current.flatMap { tasks[$0.id] } }

    func commandCancellation() -> @Sendable () -> Void {
        let task = commandWork
        let cancellation = current?.cancellation
        return {
            cancellation?.cancel(); task?.cancel()
        }
    }

    func finishWork() async {
        while let task = tasks.values.first { await task.value }
    }

    private func track(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !suspending, tasks.count < 64 else { return nil }
        let id = UUID()
        let task = Task {
            defer { tasks[id] = nil }
            await work()
        }
        tasks[id] = task
        return task
    }

    func cancelPendingCommands() {
        suspending = true
        remoteRevision += 1
        remoteTask?.cancel()
        cancel()
        for task in tasks.values { task.cancel() }
    }

    func cancelAndWait() async {
        cancelPendingCommands()
        while let task = tasks.values.first { await task.value }
        await pickerTask?.value
    }

    func shutdown() async {
        guard !stopped else { await cancelAndWait(); return }
        stopped = true
        await cancelAndWait()
        remoteRevision += 1; remoteTask?.cancel(); await remoteTask?.value; remoteTask = nil
        cancel()
        while let task = tasks.values.first { await task.value }
        report = nil
        root = nil
        history = []
        error = nil
        scannedEntries = 0
        removing = false
        loading.reset()
    }

    func chooseFolder() {
        guard !stopped, !suspending, !removing else { return }
        if let folderPicker { folderPicker.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        folderPicker = panel
        let response = AsyncStream<NSApplication.ModalResponse>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        pickerTask = Task { [self, panel] in
            defer { folderPicker = nil; pickerTask = nil }
            for await value in response.stream {
                guard !stopped, !suspending, value == .OK, let url = panel.url else { return }
                scan(url.path)
            }
        }
        panel.begin { value in
            response.continuation.yield(value)
            response.continuation.finish()
        }
    }
}
