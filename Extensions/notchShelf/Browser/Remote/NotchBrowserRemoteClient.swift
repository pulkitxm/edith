import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class NotchBrowserRemoteClient {
    typealias Invoke = @MainActor (NotchBrowserRemoteRequest) async throws -> Data
    private(set) var state: NotchBrowserClientState
    private let request:
        @MainActor (NotchBrowserRemoteRequest.Operation) -> NotchBrowserRemoteRequest?
    private let invoke: Invoke
    private var actionTask: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    private var lastHeld: Bool?
    private var pending = 0
    private(set) var lease: NotchBrowserLease?
    private var leaseEnd: NotchBrowserRemoteRequest?
    private var renewal: Task<Void, Never>?
    private var teardown: Task<Void, Never>?
    var updated: ((NotchBrowserClientState) -> Void)?
    var failed: ((String) -> Void)?
    var revoked: (() -> Void)?

    var hasLiveLease: Bool { !stopped && lease.map { $0.expiresAt > Date() } == true }

    init(
        state: NotchBrowserClientState,
        request:
            @escaping @MainActor (NotchBrowserRemoteRequest.Operation) -> NotchBrowserRemoteRequest?,
        invoke: @escaping Invoke
    ) {
        self.state = state
        self.request = request
        self.invoke = invoke
    }

    func apply(_ state: NotchBrowserClientState) { self.state = state; updated?(state) }

    func perform(
        _ operation: NotchBrowserRemoteRequest.Operation,
        configure: (inout NotchBrowserRemoteRequest) -> Void = { _ in },
        completion: (() -> Void)? = nil
    ) {
        guard !stopped, pending < 32, var request = request(operation) else { return }
        configure(&request)
        let token = generation
        let previous = actionTask
        pending += 1
        actionTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { pending -= 1 }
            guard !stopped, generation == token, !Task.isCancelled else { return }
            do {
                let data = try await invoke(request)
                try Task.checkCancellation()
                guard !stopped, generation == token, data.count <= NotchPanelEngine.maximumBytes
                else { return }
                apply(try JSONDecoder().decode(NotchBrowserClientState.self, from: data))
                completion?()
            } catch {
                if !stopped, generation == token, !Task.isCancelled {
                    failed?(error.localizedDescription)
                }
            }
        }
    }

    func save(_ session: BrowserSession) { perform(.save) { $0.session = session } }
    func held(_ held: Bool) {
        guard lastHeld != held else { return }
        lastHeld = held
        perform(.held) { $0.held = held }
    }

    func importProfile(_ id: String) async throws -> (NotchBrowserImport, ChromeProfileSnapshot) {
        guard !stopped, var start = request(.importStart) else {
            throw ExtensionPeerError.unavailable
        }
        start.profileID = id
        let token = generation
        let descriptor = try JSONDecoder().decode(
            NotchBrowserImport.self, from: await invoke(start))
        do {
            lease = descriptor.lease
            var cleanup = start
            cleanup = NotchBrowserRemoteRequest(
                identity: start.identity, displayID: start.displayID,
                presentationID: start.presentationID, operation: .leaseEnd)
            cleanup.lease = descriptor.lease
            leaseEnd = cleanup
            guard !stopped, generation == token, descriptor.profile.directory == id,
                (1...33554432).contains(descriptor.byteCount),
                descriptor.lease.profileID == id, descriptor.lease.revision == 1,
                descriptor.lease.ownershipID == start.identity.ownershipID,
                descriptor.lease.presentationID == start.presentationID,
                descriptor.lease.displayID == start.displayID,
                descriptor.lease.expiresAt > Date(),
                descriptor.lease.expiresAt.timeIntervalSinceNow <= 121
            else { throw ExtensionPeerError.invalidRequest }
            var bytes = Data()
            var offset = 0
            while offset < descriptor.byteCount {
                try Task.checkCancellation()
                guard !stopped, generation == token, var read = request(.importRead) else {
                    throw ExtensionPeerError.unavailable
                }
                read.importID = descriptor.id; read.offset = offset
                read.lease = lease
                let data = try await invoke(read)
                guard data.count <= NotchPanelEngine.maximumBytes else {
                    throw ExtensionPeerError.invalidRequest
                }
                let chunk = try JSONDecoder().decode(NotchBrowserImportChunk.self, from: data)
                guard chunk.id == descriptor.id, chunk.offset == offset, !chunk.bytes.isEmpty,
                    chunk.bytes.count <= 65536,
                    chunk.nextOffset == offset + chunk.bytes.count,
                    chunk.nextOffset <= descriptor.byteCount
                else { throw ExtensionPeerError.invalidRequest }
                bytes.append(chunk.bytes); offset = chunk.nextOffset
            }
            guard !stopped, generation == token else { throw CancellationError() }
            let snapshot = try JSONDecoder().decode(ChromeProfileSnapshot.self, from: bytes)
            if var end = request(.importEnd) {
                end.importID = descriptor.id; _ = try await invoke(end)
            }
            try Task.checkCancellation()
            guard !stopped, generation == token else { throw CancellationError() }
            scheduleRenewal()
            return (descriptor, snapshot)
        } catch {
            if var end = request(.importEnd) {
                end.importID = descriptor.id; _ = try? await invoke(end)
            }
            await endLease()
            throw error
        }
    }

    func beginDownload(_ name: String) async throws -> NotchBrowserDownloadDescriptor {
        guard hasLiveLease, var input = request(.downloadStart) else {
            throw ExtensionPeerError.unavailable
        }
        input.fileName = name
        input.lease = lease
        return try JSONDecoder().decode(
            NotchBrowserDownloadDescriptor.self, from: await invoke(input))
    }
    func publishDownload(_ descriptor: NotchBrowserDownloadDescriptor, file: URL) async throws
        -> String
    {
        guard !stopped, let handle = try? FileHandle(forReadingFrom: file) else {
            throw ExtensionPeerError.unavailable
        }
        defer { try? handle.close() }
        do {
            var offset: UInt64 = 0
            while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
                try Task.checkCancellation()
                guard !stopped, var input = request(.downloadWrite) else {
                    throw ExtensionPeerError.unavailable
                }
                input.downloadID = descriptor.id; input.byteOffset = offset; input.bytes = bytes
                input.lease = lease
                _ = try await invoke(input)
                offset += UInt64(bytes.count)
            }
            guard !stopped, var commit = request(.downloadCommit) else {
                throw ExtensionPeerError.unavailable
            }
            commit.downloadID = descriptor.id
            commit.lease = lease
            return try JSONDecoder().decode(
                NotchBrowserDownloadDescriptor.self, from: await invoke(commit)
            ).name
        } catch {
            if var cancel = request(.downloadCancel) {
                cancel.downloadID = descriptor.id; _ = try? await invoke(cancel)
            }
            throw error
        }
    }
    func cancelDownload(_ descriptor: NotchBrowserDownloadDescriptor) async {
        if var input = request(.downloadCancel) {
            input.downloadID = descriptor.id; _ = try? await invoke(input)
        }
    }

    func drainActions() async { await actionTask?.value }
    func stop() {
        guard !stopped else { return }
        stopped = true; generation = UUID(); actionTask?.cancel(); updated = nil;
        failed = nil
        renewal?.cancel()
        let actions = actionTask
        let renewing = renewal
        teardown = Task {
            await actions?.value
            await renewing?.value
            await endLease()
        }
        revoked = nil
    }

    func stopAndWait() async { stop(); await teardown?.value }

    func endLease() async {
        renewal?.cancel(); renewal = nil
        let cleanup = leaseEnd
        lease = nil; leaseEnd = nil
        if let cleanup { _ = try? await invoke(cleanup) }
    }

    func renewLease() async throws {
        guard hasLiveLease, let current = lease, var input = request(.leaseRenew) else {
            throw ExtensionPeerError.unavailable
        }
        input.lease = current
        let next = try JSONDecoder().decode(NotchBrowserLease.self, from: await invoke(input))
        try Task.checkCancellation()
        guard !stopped, lease == current, next.id == current.id,
            next.ownershipID == current.ownershipID, next.presentationID == current.presentationID,
            next.displayID == current.displayID, next.generation == current.generation,
            next.profileID == current.profileID, next.revision == current.revision + 1,
            next.expiresAt > Date(), next.expiresAt.timeIntervalSinceNow <= 121
        else { throw ExtensionPeerError.invalidRequest }
        lease = next; leaseEnd?.lease = next
    }

    private func scheduleRenewal() {
        renewal?.cancel()
        renewal = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                    guard let self else { return }
                    try await renewLease()
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.failed?(error.localizedDescription)
                    self?.revoked?()
                    await self?.endLease()
                    return
                }
            }
        }
    }
}
