import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class FinderEntryProjection {
    typealias Sort = @Sendable ([RemoteFileEntry], FileSortKey, Bool) throws -> [RemoteFileEntry]

    private(set) var entries: [RemoteFileEntry] = []
    private(set) var isUpdating = false
    @ObservationIgnored private var worker: Task<[RemoteFileEntry], Error>?
    @ObservationIgnored private var publication: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let sort: Sort
    static let backgroundThreshold = 2_000

    init(
        sort: @escaping Sort = { entries, key, ascending in
            try FileSorting.sortCheckingCancellation(entries, by: key, ascending: ascending)
        }
    ) {
        self.sort = sort
    }

    deinit { worker?.cancel(); publication?.cancel() }

    func update(
        entries: [RemoteFileEntry], searchResults: [RemoteFileEntry]?, showHidden: Bool,
        key: FileSortKey, ascending: Bool
    ) {
        cancel()
        generation = UUID()
        if let searchResults {
            self.entries = searchResults
            return
        }
        guard entries.count > Self.backgroundThreshold else {
            let visible = showHidden ? entries : entries.filter { !$0.isHidden }
            self.entries = FileSorting.sort(visible, by: key, ascending: ascending)
            return
        }
        self.entries = []
        isUpdating = true
        let current = generation
        let sort = sort
        worker = Task.detached(priority: .userInitiated) {
            var visible: [RemoteFileEntry] = []
            visible.reserveCapacity(entries.count)
            for (index, entry) in entries.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                if showHidden || !entry.isHidden { visible.append(entry) }
            }
            return try sort(visible, key, ascending)
        }
        guard let active = worker else { return }
        publication = Task { [weak self] in
            let result = try? await active.value
            guard !Task.isCancelled, let self, generation == current else { return }
            if let result { self.entries = result }
            isUpdating = false
            self.worker = nil
            publication = nil
        }
    }

    func cancel() {
        worker?.cancel()
        publication?.cancel()
        worker = nil
        publication = nil
        isUpdating = false
    }

    func wait() async { await publication?.value }
}
