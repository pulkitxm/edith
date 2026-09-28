import EdithKit
import Foundation
import Observation

@MainActor @Observable
final class BlitzTreeModel {
    private(set) var report: BlitzTreeReport?
    private(set) var scanning = false
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
        cancel()
        if remember, let root, root != path { history.append(root) }
        root = path
        report = nil
        error = nil
        scanning = true
        let generation = generation
        task = Task {
            do {
                let result = try await client.scan(root: path)
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
        guard let previous = history.popLast() else { return }
        scan(previous, remember: false)
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        scanning = false
    }
}
