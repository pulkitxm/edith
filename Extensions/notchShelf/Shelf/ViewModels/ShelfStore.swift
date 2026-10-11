import EdithExtensionSupport
import EdithExtensionUI
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
        let itemID: UUID?
        let completion: (ShelfItem?) -> Void
    }

    private(set) var items: [ShelfItem] = []
    let root: URL
    private var changeObserver: NSObjectProtocol?
    private var incomingDirectories: [UUID: ShelfIncomingDirectory] = [:]
    private var heldPromiseDestinations: Set<UUID> = []
    private var heldPromiseAdoptions: [UUID: Int] = [:]
    private var discardedPromiseDestinations: Set<UUID> = []
    private var retainedActionSelection: ShelfPinnedSelection?
    private var pendingPromiseAdoptions: [PendingPromiseAdoption] = []
    private var indexRefresh: Task<Void, Never>?
    private var mutationGeneration = 0
    private var stopped = false
    var actionSelectionRetained: Bool { retainedActionSelection != nil }
    var onExternalChange: (@MainActor () -> Void)?

    init(root: URL = ShelfIndex.root) {
        self.root = root
        let indexRoot = root
        enqueueIndexRefresh {
            (try? ShelfMutationExecution.pinnedSelection(root: indexRoot))?.items
        }
        changeObserver = NotchWorkerIPC.observe(
            NotchWorkerIPC.Name.shelfChanged,
            info: { [weak self] info in
                guard info["sender"] as? String != Self.senderID else { return }
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
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
        guard !stopped else { return }
        let previous = indexRefresh
        indexRefresh = Task { [weak self] in
            await previous?.value
            guard let self, !self.stopped, self.retainedActionSelection == nil else { return }
            let generation = self.mutationGeneration
            let refreshed = await Task.detached(priority: .utility) { operation() }.value
            guard let refreshed, !self.stopped, !Task.isCancelled,
                self.retainedActionSelection == nil,
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

    func beginSuspension() {
        stopped = true
        indexRefresh?.cancel()
        onExternalChange = nil
        NotchWorkerIPC.stopObserving(changeObserver); changeObserver = nil
    }

    func stopAndWait() async {
        beginSuspension()
        await indexRefresh?.value
        indexRefresh = nil
    }

    func shutdown() {
        beginSuspension()
        cancelActionSelection()
        for id in Array(incomingDirectories.keys) { discardPromiseDestination(id: id) }
    }

    func shutdownAndWait() async {
        shutdown()
        await stopAndWait()
    }

    deinit {
        if let changeObserver { NotchWorkerIPC.stopObserving(changeObserver) }
    }

    private static let senderID = "shelfStore-\(ProcessInfo.processInfo.processIdentifier)"

    @discardableResult
    func reload() -> Bool {
        guard !stopped, retainedActionSelection == nil else { return false }
        guard let selection = try? ShelfMutationExecution.pinnedSelection(root: root) else {
            return false
        }
        publishMutation(selection.items)
        return true
    }

    func actionSelection(itemIDs: Set<UUID>) throws -> ShelfStoreActionSelection {
        guard !stopped, retainedActionSelection == nil else { throw ShelfActionSelectionError.busy }
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
        guard !stopped, retainedActionSelection == nil else { return false }
        retainedActionSelection = selection
        return true
    }

    func releaseActionSelection() {
        guard !stopped else { cancelActionSelection(); return }
        retainedActionSelection = nil
        let pending = pendingPromiseAdoptions
        pendingPromiseAdoptions = []
        for adoption in pending {
            finishPromiseAdoption(adoption)
            releasePromiseAdoption(id: adoption.id)
        }
    }

    func cancelActionSelection() {
        retainedActionSelection = nil
        let pending = pendingPromiseAdoptions
        pendingPromiseAdoptions = []
        for adoption in pending {
            discardPromiseDestination(id: adoption.id)
            releasePromiseAdoption(id: adoption.id)
        }
    }

    func fileURL(for item: ShelfItem) -> URL { root.appendingPathComponent(item.name) }

    @discardableResult
    func addCopy(of source: URL) -> ShelfItem? {
        guard !stopped, retainedActionSelection == nil else { return nil }
        guard
            let result = try? ShelfMutationExecution.addCopy(
                of: source, root: root, sender: Self.senderID)
        else { return nil }
        publishMutation(result.items)
        return result.item
    }

    @discardableResult
    func addText(_ text: String) -> ShelfItem? {
        guard !stopped, retainedActionSelection == nil else { return nil }
        guard
            let result = try? ShelfMutationExecution.addText(
                text, root: root, sender: Self.senderID)
        else { return nil }
        publishMutation(result.items)
        return result.item
    }

    @discardableResult
    func adopt(fileAt url: URL, id: UUID, itemID: UUID? = nil) -> ShelfItem? {
        guard !stopped, retainedActionSelection == nil else { return nil }
        guard let incoming = incomingDirectories[id] else { return nil }
        do {
            let result = try ShelfMutationExecution.adopt(
                fileAt: url, root: root, id: itemID ?? id, incoming: incoming, sender: Self.senderID
            )
            discardPromiseDestination(id: id)
            publishMutation(result.items)
            return result.item
        } catch {
            return nil
        }
    }

    func adoptWhenAvailable(
        fileAt url: URL, id: UUID, itemID: UUID? = nil, completion: @escaping (ShelfItem?) -> Void
    ) {
        guard !stopped, incomingDirectories[id] != nil,
            !pendingPromiseAdoptions.contains(where: { $0.id == id && $0.itemID == itemID })
        else {
            completion(nil)
            return
        }
        let adoption = PendingPromiseAdoption(
            id: id, url: url, itemID: itemID, completion: completion)
        guard !stopped, retainedActionSelection == nil else {
            heldPromiseAdoptions[id, default: 0] += 1
            pendingPromiseAdoptions.append(adoption)
            return
        }
        finishPromiseAdoption(adoption)
    }

    func promiseDestination(id: UUID) -> URL? {
        guard !stopped, retainedActionSelection == nil else { return nil }
        guard let incoming = try? ShelfIncomingDirectory() else { return nil }
        incomingDirectories[id] = incoming
        return incoming.url
    }

    func holdPromiseDestination(id: UUID) {
        guard incomingDirectories[id] != nil else { return }
        heldPromiseDestinations.insert(id)
    }

    func releasePromiseDestination(id: UUID) {
        heldPromiseDestinations.remove(id)
        if discardedPromiseDestinations.contains(id) || stopped {
            discardPromiseDestination(id: id)
        }
    }

    private func releasePromiseAdoption(id: UUID) {
        let count = heldPromiseAdoptions[id, default: 0]
        if count <= 1 {
            heldPromiseAdoptions[id] = nil
        } else {
            heldPromiseAdoptions[id] = count - 1
        }
        if discardedPromiseDestinations.contains(id) || stopped {
            discardPromiseDestination(id: id)
        }
    }

    func discardPromiseDestination(id: UUID) {
        guard !heldPromiseDestinations.contains(id), heldPromiseAdoptions[id] == nil else {
            discardedPromiseDestinations.insert(id)
            return
        }
        discardedPromiseDestinations.remove(id)
        pendingPromiseAdoptions.removeAll { $0.id == id }
        guard let incoming = incomingDirectories.removeValue(forKey: id) else { return }
        try? incoming.discard()
    }

    private func finishPromiseAdoption(_ adoption: PendingPromiseAdoption) {
        let item = adopt(fileAt: adoption.url, id: adoption.id, itemID: adoption.itemID)
        if item == nil { discardPromiseDestination(id: adoption.id) }
        adoption.completion(item)
    }

    func item(forFileURL url: URL) -> ShelfItem? {
        let path = url.standardizedFileURL.path
        return items.first { fileURL(for: $0).standardizedFileURL.path == path }
    }

    func setPositions(_ positions: [UUID: CGPoint]) {
        guard !stopped, retainedActionSelection == nil else { return }
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
        guard !stopped, retainedActionSelection == nil else { throw ShelfActionSelectionError.busy }
        let result = try ShelfMutationExecution.remove(
            ids: Set(members.map(\.id)), root: root, sender: Self.senderID)
        publishMutation(result.items)
    }

    func purgeExpired(keep: ShelfKeepDuration, now: Date = Date()) {
        guard !stopped, retainedActionSelection == nil else { return }
        let indexRoot = root
        let sender = Self.senderID
        enqueueIndexRefresh {
            let result = try? ShelfMutationExecution.purgeExpired(
                keep: keep, now: now, root: indexRoot, sender: sender)
            return result?.items
        }
    }
}
