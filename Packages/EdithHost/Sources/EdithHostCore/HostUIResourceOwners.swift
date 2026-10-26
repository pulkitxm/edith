import Foundation

@MainActor
final class HostUIResourceOwners {
    private var owners = Set<UUID>()
    private var cleanups: [String: () -> Void] = [:]
    private var cleanupOrder: [String] = []
    private var exclusiveClose: UUID?

    func acquire(_ id: UUID) throws {
        guard exclusiveClose == nil, owners.insert(id).inserted else {
            throw HostWorkerError.rejected
        }
    }

    func bridge(for id: UUID, scope: String = "app") -> NSObject {
        HostUIResourceLease(owners: self, id: id, scope: scope)
    }

    func beginExclusiveClose(_ id: UUID) -> Bool {
        guard owners == [id], exclusiveClose == nil else { return false }
        exclusiveClose = id
        return true
    }

    func endExclusiveClose(_ id: UUID) {
        if exclusiveClose == id { exclusiveClose = nil }
    }

    func release(_ id: UUID) {
        guard owners.remove(id) != nil else { return }
        endExclusiveClose(id)
        guard owners.isEmpty else { return }
        let pending = cleanupOrder.compactMap { cleanups[$0] }
        cleanups = [:]
        cleanupOrder = []
        for cleanup in pending { cleanup() }
    }

    fileprivate func canStop(for id: UUID) -> Bool { owners.subtracting([id]).isEmpty }

    fileprivate func cleanup(for id: UUID, key: String, operation: @escaping () -> Void) {
        if canStop(for: id) {
            cleanups[key] = nil
            cleanupOrder.removeAll { $0 == key }
            operation()
        } else {
            if cleanups[key] == nil { cleanupOrder.append(key) }
            cleanups[key] = operation
        }
    }
}

@MainActor
private final class HostUIResourceLease: NSObject {
    private let owners: HostUIResourceOwners
    private let id: UUID
    private let scope: String

    init(owners: HostUIResourceOwners, id: UUID, scope: String) {
        self.owners = owners
        self.id = id
        self.scope = scope
    }

    @objc func canStopSharedResources() -> Bool { owners.canStop(for: id) }

    @objc(scheduleSharedCleanup:operation:)
    func scheduleSharedCleanup(_ key: NSString, operation: @escaping @convention(block) () -> Void)
    {
        owners.cleanup(for: id, key: scope + ":" + (key as String), operation: operation)
    }
}
