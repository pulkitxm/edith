import EdithExtensionSupport
import Foundation

@MainActor final class NotchBrowserCommandClient {
    typealias Invoke = @MainActor (NotchBrowserRemoteRequest) async throws -> Data
    private let request:
        @MainActor (NotchBrowserRemoteRequest.Operation) -> NotchBrowserRemoteRequest?
    private let invoke: Invoke
    private let perform: @MainActor (NotchBrowserRequest) throws -> NotchBrowserSnapshot
    private var lease: NotchBrowserCommandLease?
    private var ownerRequest: NotchBrowserRemoteRequest?
    private var task: Task<Void, Never>?
    private var renewal: Task<Void, Never>?
    private var teardown: Task<Void, Never>?
    private var again = false
    private var stopped = false

    init(
        request:
            @escaping @MainActor (NotchBrowserRemoteRequest.Operation) -> NotchBrowserRemoteRequest?,
        invoke: @escaping Invoke,
        perform: @escaping @MainActor (NotchBrowserRequest) throws -> NotchBrowserSnapshot
    ) {
        self.request = request; self.invoke = invoke; self.perform = perform
    }

    func refresh() {
        guard !stopped else { return }
        if task != nil { again = true; return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            repeat {
                again = false
                do { try await drain() } catch {}
            } while again && !stopped && !Task.isCancelled
        }
    }

    private func drain() async throws {
        guard var attach = request(.commandAttach), !stopped else {
            throw ExtensionPeerError.unavailable
        }
        attach.commandLease = lease
        let bytes = try await invoke(attach)
        guard bytes.count <= NotchPanelEngine.maximumBytes else {
            throw ExtensionPeerError.invalidRequest
        }
        let next = try JSONDecoder().decode(NotchBrowserCommandLease.self, from: bytes)
        guard next.ownershipID == attach.identity.ownershipID,
            next.presentationID == attach.presentationID, next.displayID == attach.displayID,
            next.expiresAt > Date(), next.expiresAt.timeIntervalSinceNow <= 121
        else { throw ExtensionPeerError.invalidRequest }
        lease = next
        ownerRequest = attach
        if stopped || Task.isCancelled {
            await end(next, original: attach)
            lease = nil
            return
        }
        if renewal == nil {
            renewal = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.renewal = nil; self?.refresh()
            }
        }
        while !stopped && !Task.isCancelled {
            guard var take = request(.commandTake) else { throw ExtensionPeerError.unavailable }
            take.commandLease = next
            let bytes = try await invoke(take)
            guard bytes.count <= NotchPanelEngine.maximumBytes else {
                throw ExtensionPeerError.invalidRequest
            }
            let commands = try JSONDecoder().decode([NotchBrowserQueuedCommand].self, from: bytes)
            guard commands.count <= 1 else { throw ExtensionPeerError.invalidRequest }
            guard let command = commands.first else { return }
            try command.request.validate()
            guard command.leaseID == next.id, command.deadline > Date(),
                command.deadline.timeIntervalSinceNow <= 8.1,
                var validation = request(.commandValidate)
            else { throw ExtensionPeerError.invalidRequest }
            validation.commandLease = next; validation.commandID = command.id
            _ = try await invoke(validation)
            try Task.checkCancellation()
            guard !stopped, lease == next, request(.commandResult) != nil,
                command.deadline > Date()
            else { throw ExtensionPeerError.unavailable }
            let result: NotchBrowserCommandResult
            do {
                result = .init(id: command.id, snapshot: try perform(command.request), error: nil)
            } catch {
                let message = String(error.localizedDescription.prefix(128))
                result = .init(
                    id: command.id, snapshot: nil,
                    error: message.isEmpty ? "The browser action failed." : message)
            }
            guard var reply = request(.commandResult), !stopped else {
                throw ExtensionPeerError.unavailable
            }
            reply.commandLease = next; reply.commandResult = result
            _ = try await invoke(reply)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        renewal?.cancel(); renewal = nil
        let current = task; current?.cancel()
        let lease = lease
        let original = ownerRequest
        teardown = Task {
            await current?.value
            if let lease, let original { await end(lease, original: original) }
            self.lease = nil
        }
    }

    func stopAndWait() async { stop(); await teardown?.value }

    private func end(_ lease: NotchBrowserCommandLease, original: NotchBrowserRemoteRequest) async {
        var end = NotchBrowserRemoteRequest(
            identity: original.identity, displayID: original.displayID,
            presentationID: original.presentationID, operation: .commandEnd)
        end.commandLease = lease
        _ = try? await invoke(end)
    }
}
