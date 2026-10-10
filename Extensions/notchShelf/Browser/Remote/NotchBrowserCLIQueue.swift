import EdithExtensionSupport
import Foundation

@MainActor final class NotchBrowserCLIQueue {
    private struct Pending {
        let command: NotchBrowserQueuedCommand
        let owner: UUID
        let continuation: CheckedContinuation<NotchBrowserSnapshot, Error>
        let timeout: Task<Void, Never>
        var delivered = false
    }
    private var leases: [UUID: NotchBrowserCommandLease] = [:]
    private var expiries: [UUID: Task<Void, Never>] = [:]
    private var pending: [UUID: Pending] = [:]
    private var stopped = false
    private let now: () -> Date
    var changed: (() -> Void)?
    var admitted: (NotchBrowserCommandLease) -> Bool = { _ in false }
    var pendingCount: Int { pending.count }

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func attach(_ request: NotchBrowserRemoteRequest) throws -> NotchBrowserCommandLease {
        expire()
        guard !stopped, leases[request.presentationID] != nil || leases.count < 8 else {
            throw ExtensionPeerError.unavailable
        }
        let current = leases[request.presentationID]
        if let current, let supplied = request.commandLease, supplied != current {
            throw ExtensionPeerError.invalidRequest
        }
        let renewing = current != nil && request.commandLease == current
        let lease = NotchBrowserCommandLease(
            id: renewing ? current!.id : UUID(),
            ownershipID: request.identity.ownershipID, presentationID: request.presentationID,
            displayID: request.displayID, expiresAt: now().addingTimeInterval(120))
        guard admitted(lease) else { throw ExtensionPeerError.unavailable }
        if !renewing { release(request.presentationID) }
        leases[request.presentationID] = lease
        expiries.removeValue(forKey: request.presentationID)?.cancel()
        expiries[request.presentationID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            guard self?.leases[lease.presentationID] == lease else { return }
            self?.release(lease.presentationID)
        }
        return lease
    }

    func invoke(_ request: NotchBrowserRequest, timeout: TimeInterval = 8) async throws
        -> NotchBrowserSnapshot
    {
        try request.validate()
        expire()
        guard !stopped, timeout.isFinite, (0.01...8).contains(timeout), pending.count < 8 else {
            throw ExtensionPeerError.unavailable
        }
        let available = leases.values.filter(admitted).sorted {
            if $0.expiresAt == $1.expiresAt {
                return $0.presentationID.uuidString < $1.presentationID.uuidString
            }
            return $0.expiresAt > $1.expiresAt
        }
        guard let lease = available.first else {
            throw NotchBrowserActionError(
                "Open the enabled Notch browser before using this command.")
        }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let command = NotchBrowserQueuedCommand(
                    id: id, leaseID: lease.id, request: request,
                    deadline: now().addingTimeInterval(timeout))
                let expiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.finish(
                        id, .failure(NotchBrowserActionError("The browser request timed out.")))
                }
                pending[id] = Pending(
                    command: command, owner: lease.presentationID, continuation: continuation,
                    timeout: expiry)
                changed?()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }

    func take(_ request: NotchBrowserRemoteRequest) throws -> [NotchBrowserQueuedCommand] {
        let lease = try validate(request)
        let waiting = pending.values.filter {
            $0.owner == lease.presentationID && !$0.delivered
        }.sorted { $0.command.deadline < $1.command.deadline }
        guard let next = waiting.first else { return [] }
        pending[next.command.id]?.delivered = true
        return [next.command]
    }

    func validateCommand(_ request: NotchBrowserRemoteRequest) throws {
        let lease = try validate(request)
        guard let id = request.commandID, let work = pending[id], work.delivered,
            work.owner == lease.presentationID, work.command.leaseID == lease.id,
            work.command.deadline > now()
        else { throw ExtensionPeerError.invalidRequest }
    }

    func complete(_ request: NotchBrowserRemoteRequest) throws {
        let lease = try validate(request)
        guard let result = request.commandResult, let work = pending[result.id], work.delivered,
            work.owner == lease.presentationID, work.command.leaseID == lease.id,
            work.command.deadline > now(),
            (result.snapshot == nil) != (result.error == nil),
            result.error.map({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains(0) })
                ?? true
        else { throw ExtensionPeerError.invalidRequest }
        if let snapshot = result.snapshot {
            guard snapshot.tabs.count <= 128, snapshot.profiles.count <= 128,
                Set(snapshot.tabs.map(\.id)).count == snapshot.tabs.count,
                snapshot.tabs.allSatisfy({
                    UUID(uuidString: $0.id) != nil && (1...128).contains($0.index)
                        && $0.title.utf8.count <= 16384 && ($0.url?.utf8.count ?? 0) <= 16384
                }), try JSONEncoder().encode(snapshot).count <= NotchPanelEngine.maximumBytes
            else { throw ExtensionPeerError.invalidRequest }
            finish(result.id, .success(snapshot))
        } else {
            finish(result.id, .failure(NotchBrowserActionError(result.error!)))
        }
    }

    func cancel(_ request: NotchBrowserRemoteRequest) throws {
        let lease = try validate(request)
        guard let id = request.commandID, let work = pending[id], work.owner == lease.presentationID
        else { throw ExtensionPeerError.invalidRequest }
        finish(id, .failure(CancellationError()))
    }

    func end(_ request: NotchBrowserRemoteRequest) throws {
        guard let supplied = request.commandLease,
            supplied.presentationID == request.presentationID,
            supplied.displayID == request.displayID,
            supplied.ownershipID == request.identity.ownershipID,
            leases[request.presentationID].map({ $0.id == supplied.id }) ?? true
        else { throw ExtensionPeerError.invalidRequest }
        release(request.presentationID)
    }

    func release(_ presentationID: UUID) {
        leases.removeValue(forKey: presentationID)
        expiries.removeValue(forKey: presentationID)?.cancel()
        for id in pending.keys.filter({ pending[$0]?.owner == presentationID }) {
            finish(id, .failure(ExtensionPeerError.unavailable))
        }
    }

    func stop() {
        stopped = true
        for owner in Array(leases.keys) { release(owner) }
        changed = nil
    }

    private func expire() {
        for lease in Array(leases.values) where lease.expiresAt <= now() || !admitted(lease) {
            release(lease.presentationID)
        }
    }

    private func validate(_ request: NotchBrowserRemoteRequest) throws -> NotchBrowserCommandLease {
        expire()
        guard !stopped, let supplied = request.commandLease,
            let lease = leases[request.presentationID], supplied == lease,
            lease.ownershipID == request.identity.ownershipID,
            lease.displayID == request.displayID, lease.expiresAt > now(), admitted(lease)
        else { throw ExtensionPeerError.invalidRequest }
        return lease
    }

    private func finish(_ id: UUID, _ result: Result<NotchBrowserSnapshot, Error>) {
        guard let work = pending.removeValue(forKey: id) else { return }
        work.timeout.cancel()
        work.continuation.resume(with: result)
        changed?()
    }
}
