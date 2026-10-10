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
        guard !stopped else { return }
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
        guard let engineClient, !stopped else { return }
        let revision = remoteRevision
        do {
            let data = try await engineClient.invoke("blitztree.ui.snapshot")
            guard !stopped, !Task.isCancelled, revision == remoteRevision else { return }
            applyRemote(try JSONDecoder().decode(BlitzTreeUISnapshot.self, from: data))
        } catch is CancellationError {} catch {
            if !stopped { self.error = error.localizedDescription }
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
        guard let engineClient, !stopped else { return }
        remoteTask?.cancel(); remoteRevision += 1
        let revision = remoteRevision
        remoteTask = Task {
            defer { if revision == remoteRevision { remoteTask = nil } }
            do {
                _ = try await engineClient.invoke(command, payload: payload, timeout: 30)
                guard !stopped, !Task.isCancelled, revision == remoteRevision else { return }
                await refreshRemote()
            } catch is CancellationError {} catch {
                guard !stopped, revision == remoteRevision else { return }
                self.error = error.localizedDescription; loading.fail(loading.begin(), error: error)
            }
        }
    }

    func scan(_ path: String, remember: Bool = true) {
        guard !stopped, !removing else { return }
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
                let result = try await client.scan(root: path) { count in
                    Task { @MainActor [weak self] in
                        guard let self, !self.stopped, self.loading.isCurrent(generation) else {
                            return
                        }
                        self.scannedEntries = count
                    }
                }
                guard !stopped, loading.isCurrent(generation) else { return }
                report = result
                root = result.root
                previewToken = UUID()
                loading.complete(generation)
            } catch {
                guard !stopped, loading.owns(generation), !Task.isCancelled else { return }
                loading.fail(generation, error: error)
                self.error = loading.errorMessage
            }
        }
    }

    func back() {
        if engineClient != nil { remote("blitztree.ui.back"); return }
        guard !stopped, !removing, let previous = history.popLast() else { return }
        scan(previous, remember: false)
    }

    func cancel() {
        if engineClient != nil, !stopped { remote("blitztree.cancel"); return }
        loading.cancel()
        if let current {
            current.cancellation.cancel()
            tasks[current.id]?.cancel()
        }
        folderPicker?.cancel(nil)
        folderPicker?.orderOut(nil)
        folderPicker = nil
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
        guard !stopped, !scanning, !removing, let report,
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
                guard !stopped, loading.isCurrent(generation) else { return }
                removing = false
                loading.complete(generation)
                scan(report.root, remember: false)
            } catch {
                guard !stopped, loading.owns(generation), !Task.isCancelled else { return }
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

    func finishWork() async {
        while let current, let task = tasks[current.id] { await task.value }
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
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
        guard !stopped, !removing else { return }
        if let folderPicker { folderPicker.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        folderPicker = panel
        panel.begin { [weak self, weak panel] response in
            guard let self, let panel, self.folderPicker === panel else { return }
            self.folderPicker = nil
            guard !self.stopped, response == .OK, let url = panel.url else { return }
            self.scan(url.path)
        }
    }
}
