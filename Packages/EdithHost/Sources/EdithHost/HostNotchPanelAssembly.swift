import AppKit
import EdithExtensionSupport
import EdithHostCore

@MainActor
final class HostNotchPanelAssembly {
    typealias Create = @MainActor (HostExtensionContentRequest) async throws -> HostNotchSceneLease

    let panel: HostNotchPanel
    let container = HostNotchContainerController()
    private let create: Create
    private let present: @MainActor (HostNotchPanel) -> Void
    private let measure: @MainActor (UUID, Double) -> Void
    private let didRelease: @MainActor (HostExtensionContentRequest) async throws -> Void
    private let reportFailure: @MainActor (UUID, String) -> Void
    private var records: [UUID: Record] = [:]
    private var creating: [UUID: Task<Void, Never>] = [:]
    private var creationRequests: [UUID: UUID] = [:]
    private var retiring: [UUID: HostNotchSceneLease] = [:]
    private var closing: [UUID: Task<Void, Never>] = [:]
    private(set) var state: HostNotchPanelState?
    private(set) var failures: [UUID: String] = [:]
    private var stopped = false
    private var association: (UUID, HostNotchWindowAssociation)?

    func associate(_ context: HostNotchWindowAssociation) throws {
        guard association == nil, state == nil, !stopped else {
            throw HostNotchPanelError.staleState
        }
        association = (try context.associate(panel), context)
    }

    func containsLivePresentation(_ id: UUID) -> Bool {
        !stopped && records.values.contains { $0.request.presentationID == id && $0.lease != nil }
    }

    func slot(for request: HostExtensionContentRequest) -> HostNotchNativeSlot? {
        guard ownsVisiblePanel else { return nil }
        return records.values.first { $0.request == request }?.slot
    }

    init(
        create: @escaping Create,
        present: @escaping @MainActor (HostNotchPanel) -> Void = { $0.orderFrontRegardless() },
        didRelease: @escaping @MainActor (HostExtensionContentRequest) async throws -> Void = { _ in
        },
        measure: @escaping @MainActor (UUID, Double) -> Void = { _, _ in },
        reportFailure: @escaping @MainActor (UUID, String) -> Void = { _, _ in }
    ) {
        self.didRelease = didRelease
        self.create = create
        self.present = present
        self.measure = measure
        self.reportFailure = reportFailure
        panel = HostNotchPanel()
        panel.contentViewController = container
    }

    var presentationIDs: Set<UUID> {
        Set(records.values.map { $0.request.presentationID }).union(retiring.keys)
    }
    var ownsVisiblePanel: Bool { !stopped && state?.visible == true && !records.isEmpty }
    var attachedCount: Int { records.values.filter { $0.lease != nil }.count }
    var pendingCleanupCount: Int { retiring.count }

    func accept(_ next: HostNotchPanelState, admission: HostNotchPanelAdmission) throws {
        guard !stopped else { throw HostNotchPanelError.staleState }
        if let state {
            guard next.ownershipID == state.ownershipID, next.version == state.version,
                next.displayID == state.displayID, next.presentationID == state.presentationID,
                next.revision > state.revision
            else { throw HostNotchPanelError.staleState }
        }
        try next.validate(admission)
        state = next
        panel.setFrame(next.panelFrame(display: admission.display), display: false)
        panel.acceptsKeyFocus = next.acceptsKeyFocus
        panel.ignoresMouseEvents = !next.visible || !next.acceptsPointer
        panel.alphaValue = next.visible ? 1 : 0
        container.apply(next, size: next.panelSize(display: admission.display))
        var wanted = Set<UUID>()
        if next.visible {
            wanted.insert(next.presentationID)
            upsert(
                id: next.presentationID,
                request: HostExtensionContentRequest(
                    extensionID: "notchShelf", location: "notch",
                    section: "panel." + String(next.displayID), presentationID: next.presentationID),
                slot: nil)
            for slot in next.slots {
                wanted.insert(slot.id)
                let current = records[slot.id]
                let presentationID: UUID
                if let current, let previous = current.slot,
                    previous.providerID == slot.providerID,
                    previous.providerVersion == slot.providerVersion,
                    previous.kind == slot.kind, previous.tile == slot.tile
                {
                    presentationID = current.request.presentationID
                } else {
                    presentationID = UUID()
                }
                upsert(
                    id: slot.id, request: try slot.request(presentationID: presentationID),
                    slot: slot)
            }
        }
        for id in Array(records.keys) where !wanted.contains(id) { remove(id) }
        if next.visible { present(panel) } else { panel.orderOut(nil) }
    }

    func synchronize(activeVersions: [String: String], hiddenWidgets: Set<SurfaceWidget>) {
        guard !stopped, let state else { return }
        if activeVersions["notchShelf"] != state.version {
            hide()
            return
        }
        for (id, record) in Array(records) {
            guard let slot = record.slot else { continue }
            if activeVersions[slot.providerID] != slot.providerVersion
                || hiddenWidgets.contains(slot.tile.widget)
            {
                remove(id)
            }
        }
    }

    func hide() {
        panel.orderOut(nil)
        panel.ignoresMouseEvents = true
        panel.acceptsKeyFocus = false
        for id in Array(records.keys) { remove(id) }
    }

    func stop() async throws {
        stopped = true
        hide()
        for task in Array(creating.values) { task.cancel() }
        for task in Array(creating.values) { await task.value }
        for task in Array(closing.values) { await task.value }
        var failure: (any Error)?
        for (id, lease) in Array(retiring) {
            do {
                try await release(lease)
                retiring[id] = nil; failures[id] = nil
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        panel.close()
        if let (token, context) = association {
            association = nil
            context.remove(token)
        }
    }

    private func upsert(id: UUID, request: HostExtensionContentRequest, slot: HostNotchNativeSlot?)
    {
        if let record = records[id], record.request == request,
            record.slot?.providerVersion == slot?.providerVersion
        {
            record.slot = slot
            if let lease = record.lease {
                position(lease, record: record)
            } else if record.task == nil {
                startCreate(id: id, record: record)
            }
            return
        }
        remove(id)
        let record = Record(request: request, slot: slot)
        records[id] = record
        startCreate(id: id, record: record)
    }

    private func startCreate(id: UUID, record: Record) {
        let request = record.request
        let token = record.token
        let task = Task { [weak self, weak record] in
            guard let self, let record else { return }
            defer { creating[token] = nil; creationRequests[token] = nil; record.task = nil }
            do {
                try Task.checkCancellation()
                for (other, pending) in Array(creating)
                where other != token && creationRequests[other] == request.presentationID {
                    await pending.value
                }
                if let pending = closing[request.presentationID] { await pending.value }
                if let previous = retiring[request.presentationID] {
                    try await release(previous)
                    retiring[request.presentationID] = nil
                }
                try Task.checkCancellation()
                guard !stopped, records[id] === record else { return }
                let lease = try await create(request)
                guard !Task.isCancelled, !stopped, records[id] === record else {
                    retire(lease); return
                }
                record.lease = lease
                failures[id] = nil
                lease.measuredHeight = { [weak self, weak record] height in
                    guard let self, let record, records[id] === record, !stopped,
                        let slot = record.slot, height.isFinite, (0...1200).contains(height)
                    else { return }
                    measure(slot.id, height)
                }
                position(lease, record: record)
            } catch {
                guard !Task.isCancelled, !stopped, records[id] === record else { return }
                let message =
                    error is HostRemoteAvailabilityError
                    ? "Approve this extension in macOS extension settings to open its card."
                    : "The extension card could not open."
                failures[id] = message
                if let slot = record.slot { reportFailure(slot.id, message) }
            }
        }
        record.task = task
        creating[token] = task
        creationRequests[token] = request.presentationID
    }

    private func position(_ lease: HostNotchSceneLease, record: Record) {
        guard let state else { return }
        container.attach(
            lease.controller, rectangle: record.slot?.rectangle.frame, native: record.slot != nil)
        lease.apply(
            compact: record.slot?.tile.dense ?? true, visible: state.visible,
            width: record.slot?.rectangle.width ?? container.view.bounds.width)
    }

    private func remove(_ id: UUID) {
        guard let record = records.removeValue(forKey: id) else { return }
        record.task?.cancel()
        failures[id] = nil
        if let lease = record.lease { retire(lease) }
    }

    private func retire(_ lease: HostNotchSceneLease) {
        let id = lease.request.presentationID
        lease.detach()
        retiring[id] = lease
        guard closing[id] == nil else { return }
        closing[id] = Task { [weak self] in
            guard let self else { return }
            defer { closing[id] = nil }
            do {
                try await release(lease)
                retiring[id] = nil; failures[id] = nil
            } catch {
                failures[id] = "The extension interface is still stopping."
            }
        }
    }

    private func release(_ lease: HostNotchSceneLease) async throws {
        try await lease.close()
        try await didRelease(lease.request)
    }

    private final class Record {
        let token = UUID()
        let request: HostExtensionContentRequest
        var slot: HostNotchNativeSlot?
        var lease: HostNotchSceneLease?
        var task: Task<Void, Never>?
        init(request: HostExtensionContentRequest, slot: HostNotchNativeSlot?) {
            self.request = request
            self.slot = slot
        }
    }
}
