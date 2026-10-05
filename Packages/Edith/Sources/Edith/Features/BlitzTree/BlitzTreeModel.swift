import EdithKit
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
    private let client: BlitzTreeClient
    private var task: Task<Void, Never>?

    init(client: BlitzTreeClient = .live) {
        self.client = client
    }

    func scan(_ path: String, remember: Bool = true) {
        guard !removing else { return }
        cancel()
        if remember, let root, root != path { history.append(root) }
        root = path
        if report?.root != path { report = nil }
        error = nil
        scannedEntries = 0
        let generation = loading.begin(preservingContent: report != nil)
        task = Task { [self] in
            do {
                let result = try await client.scan(root: path) { count in
                    Task { @MainActor [weak self] in
                        guard let self, self.loading.isCurrent(generation) else { return }
                        self.scannedEntries = count
                    }
                }
                guard loading.isCurrent(generation) else { return }
                report = result
                root = result.root
                loading.complete(generation)
            } catch {
                guard loading.owns(generation) else { return }
                loading.fail(generation, error: error)
                self.error = loading.errorMessage
            }
            task = nil
        }
    }

    func back() {
        guard !removing else { return }
        guard let previous = history.popLast() else { return }
        scan(previous, remember: false)
    }

    func cancel() {
        loading.cancel()
        task?.cancel()
        task = nil
    }

    func trash(_ entry: BlitzTreeReport.Entry) {
        guard !scanning, !removing, let report else { return }
        removing = true
        error = nil
        let generation = loading.begin()
        task = Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try BlitzTreeActions.trash(entry, root: report.root)
                }.value
                removing = false
                guard loading.isCurrent(generation) else { return }
                loading.complete(generation)
                scan(report.root, remember: false)
            } catch {
                removing = false
                guard loading.owns(generation) else { return }
                loading.fail(generation, error: error)
                self.error = error.localizedDescription
                task = nil
            }
        }
    }
}
