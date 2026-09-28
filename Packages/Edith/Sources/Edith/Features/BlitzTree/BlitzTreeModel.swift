import EdithKit
import Foundation
import Observation

@MainActor @Observable
final class BlitzTreeModel {
    private(set) var report: BlitzTreeReport?
    private(set) var scanning = false
    private(set) var removing = false
    private(set) var scannedEntries: UInt64 = 0
    private(set) var root: String?
    private(set) var history: [String] = []
    private(set) var error: String?
    private let client: BlitzTreeClient
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(client: BlitzTreeClient = .live) {
        self.client = client
    }

    func scan(_ path: String, remember: Bool = true) {
        guard !removing else { return }
        cancel()
        if remember, let root, root != path { history.append(root) }
        root = path
        report = nil
        error = nil
        scanning = true
        scannedEntries = 0
        let generation = generation
        task = Task { [self] in
            do {
                let result = try await client.scan(root: path) { count in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation, self.scanning else { return }
                        self.scannedEntries = count
                    }
                }
                guard !Task.isCancelled, self.generation == generation else { return }
                report = result
                root = result.root
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.error = error.localizedDescription
            }
            scanning = false
            task = nil
        }
    }

    func back() {
        guard !removing else { return }
        guard let previous = history.popLast() else { return }
        scan(previous, remember: false)
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        scanning = false
    }

    func trash(_ entry: BlitzTreeReport.Entry) {
        guard !scanning, !removing, let report else { return }
        removing = true
        error = nil
        let generation = generation
        task = Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try BlitzTreeActions.trash(entry, root: report.root)
                }.value
                removing = false
                guard self.generation == generation else { return }
                scan(report.root, remember: false)
            } catch {
                removing = false
                guard self.generation == generation else { return }
                self.error = error.localizedDescription
                task = nil
            }
        }
    }
}
