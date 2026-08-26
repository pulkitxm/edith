import EdithKit
import Foundation

enum ShelfActionSelectionError: LocalizedError {
    case busy
    case unreadable
    case unavailable

    var errorDescription: String? {
        switch self {
        case .busy: return "a shelf share picker is already open"
        case .unreadable: return "the shelf could not be read"
        case .unavailable: return "the selected shelf items are not available"
        }
    }
}

struct ShelfStoreActionSelection {
    let snapshot: ShelfPinnedSelection
    let items: [ShelfItem]

    func fileURLs() throws -> [URL] {
        try snapshot.fileURLs(for: items.map(\.id))
    }

    func stagedFiles() throws -> ShelfStagedFiles {
        try snapshot.stagedFiles(for: items.map(\.id))
    }
}

@MainActor
final class ShelfStore {
    private struct PendingPromiseAdoption {
        let id: UUID
        let url: URL
        let completion: (ShelfItem?) -> Void
    }

    private(set) var items: [ShelfItem] = []
    private let root: URL
    private var changeObserver: NSObjectProtocol?
    private var incomingDirectories: [UUID: ShelfIncomingDirectory] = [:]
    private var retainedActionSelection: ShelfPinnedSelection?
    private var pendingPromiseAdoptions: [PendingPromiseAdoption] = []
    private var indexRefresh: Task<Void, Never>?
    private var mutationGeneration = 0
    var onExternalChange: (@MainActor () -> Void)?

    init(root: URL = ShelfIndex.root) {
        self.root = root
        let indexRoot = root
        enqueueIndexRefresh {
            (try? ShelfMutationExecution.pinnedSelection(root: indexRoot))?.items
        }
        changeObserver = IPC.observe(
            IPC.Name.shelfChanged,
            info: { [weak self] info in
                guard info["sender"] as? String != Self.senderID else { return }
                Task { @MainActor in
                    guard let self else { return }
                    if self.reload() { self.onExternalChange?() }
                }
            })
    }

    func drainIndexRefreshes() async {
        while let refresh = indexRefresh {
            await refresh.value
            if indexRefresh == refresh { return }
        }
    }

    private func enqueueIndexRefresh(_ operation: @escaping @Sendable () -> [ShelfItem]?) {
        let previous = indexRefresh
        indexRefresh = Task { [weak self] in
            await previous?.value
            guard let self, self.retainedActionSelection == nil else { return }
            let generation = self.mutationGeneration
            let refreshed = await Task.detached(priority: .utility) { operation() }.value
            guard let refreshed, self.retainedActionSelection == nil,
                generation == self.mutationGeneration
            else { return }
            self.items = refreshed
            self.onExternalChange?()
        }
    }

    private func publishMutation(_ newItems: [ShelfItem]) {
        mutationGeneration += 1
        items = newItems
    }

    deinit {
        if let changeObserver { IPC.stopObserving(changeObserver) }
    }

    private static let senderID = "shelfStore-\(ProcessInfo.processInfo.processIdentifier)"

    @discardableResult
    func reload() -> Bool {
        guard retainedActionSelection == nil else { return false }
        guard let selection = try? ShelfMutationExecution.pinnedSelection(root: root) else {
            return false
        }
        publishMutation(selection.items)
        return true
    }

    func actionSelection(itemIDs: Set<UUID>) throws -> ShelfStoreActionSelection {
        guard retainedActionSelection == nil else { throw ShelfActionSelectionError.busy }
        let selection: ShelfPinnedSelection
        do {
            selection = try ShelfMutationExecution.pinnedSelection(root: root)
        } catch {
            throw ShelfActionSelectionError.unreadable
        }
        publishMutation(selection.items)
        let members = items.filter { itemIDs.contains($0.id) }
        guard members.count == itemIDs.count, !members.isEmpty else {
            throw ShelfActionSelectionError.unavailable
        }
        do {
            _ = try selection.fileURLs(for: members.map(\.id))
        } catch {
            throw ShelfActionSelectionError.unavailable
        }
        return ShelfStoreActionSelection(snapshot: selection, items: members)
    }

    func withActionSelection<T>(
        itemIDs: Set<UUID>, perform: (ShelfStoreActionSelection) throws -> T
    ) throws -> T {
        try perform(actionSelection(itemIDs: itemIDs))
    }

    func retainActionSelection(_ selection: ShelfPinnedSelection) -> Bool {
        guard retainedActionSelection == nil else { return false }
        retainedActionSelection = selection
        return true
    }

    func releaseActionSelection() {
        retainedActionSelection = nil
        let pending = pendingPromiseAdoptions
        pendingPromiseAdoptions = []
        for adoption in pending { finishPromiseAdoption(adoption) }
    }

    func cancelActionSelection() {
        retainedActionSelection = nil
        let pending = pendingPromiseAdoptions
        pendingPromiseAdoptions = []
        for adoption in pending { discardPromiseDestination(id: adoption.id) }
    }

    func fileURL(for item: ShelfItem) -> URL { root.appendingPathComponent(item.name) }

    @discardableResult
    func addCopy(of source: URL) -> ShelfItem? {
        guard retainedActionSelection == nil else { return nil }
        guard
            let result = try? ShelfMutationExecution.addCopy(
                of: source, root: root, sender: Self.senderID)
        else { return nil }
        publishMutation(result.items)
        return result.item
    }

    @discardableResult
    func addText(_ text: String) -> ShelfItem? {
        guard retainedActionSelection == nil else { return nil }
        guard
            let result = try? ShelfMutationExecution.addText(
                text, root: root, sender: Self.senderID)
        else { return nil }
        publishMutation(result.items)
        return result.item
    }

    @discardableResult
    func adopt(fileAt url: URL, id: UUID) -> ShelfItem? {
        guard retainedActionSelection == nil else { return nil }
        guard let incoming = incomingDirectories[id] else { return nil }
        do {
            let result = try ShelfMutationExecution.adopt(
                fileAt: url, root: root, id: id, incoming: incoming, sender: Self.senderID)
            discardPromiseDestination(id: id)
            publishMutation(result.items)
            return result.item
        } catch {
            return nil
        }
    }

    func adoptWhenAvailable(
        fileAt url: URL, id: UUID, completion: @escaping (ShelfItem?) -> Void
    ) {
        guard incomingDirectories[id] != nil,
            !pendingPromiseAdoptions.contains(where: { $0.id == id })
        else {
            completion(nil)
            return
        }
        let adoption = PendingPromiseAdoption(id: id, url: url, completion: completion)
        guard retainedActionSelection == nil else {
            pendingPromiseAdoptions.append(adoption)
            return
        }
        finishPromiseAdoption(adoption)
    }

    func promiseDestination(id: UUID) -> URL? {
        guard retainedActionSelection == nil else { return nil }
        guard let incoming = try? ShelfIncomingDirectory() else { return nil }
        incomingDirectories[id] = incoming
        return incoming.url
    }

    func discardPromiseDestination(id: UUID) {
        pendingPromiseAdoptions.removeAll { $0.id == id }
        guard let incoming = incomingDirectories.removeValue(forKey: id) else { return }
        try? incoming.discard()
    }

    private func finishPromiseAdoption(_ adoption: PendingPromiseAdoption) {
        let item = adopt(fileAt: adoption.url, id: adoption.id)
        if item == nil { discardPromiseDestination(id: adoption.id) }
        adoption.completion(item)
    }

    func item(forFileURL url: URL) -> ShelfItem? {
        let path = url.standardizedFileURL.path
        return items.first { fileURL(for: $0).standardizedFileURL.path == path }
    }

    func setPositions(_ positions: [UUID: CGPoint]) {
        guard retainedActionSelection == nil else { return }
        guard
            let result = try? ShelfMutationExecution.updatePositions(
                positions, root: root, sender: Self.senderID)
        else { return }
        publishMutation(result.items)
    }

    func setPosition(_ position: CGPoint, for item: ShelfItem) {
        setPositions([item.id: position])
    }

    func remove(_ item: ShelfItem) throws {
        try remove([item])
    }

    func remove(_ members: [ShelfItem]) throws {
        guard retainedActionSelection == nil else { throw ShelfActionSelectionError.busy }
        let result = try ShelfMutationExecution.remove(
            ids: Set(members.map(\.id)), root: root, sender: Self.senderID)
        publishMutation(result.items)
    }

    func purgeExpired(keep: ShelfKeepDuration, now: Date = Date()) {
        guard retainedActionSelection == nil else { return }
        let indexRoot = root
        let sender = Self.senderID
        enqueueIndexRefresh {
            let result = try? ShelfMutationExecution.purgeExpired(
                keep: keep, now: now, root: indexRoot, sender: sender)
            return result?.items
        }
    }
}
