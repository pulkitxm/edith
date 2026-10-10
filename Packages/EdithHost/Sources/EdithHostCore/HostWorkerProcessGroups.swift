import Darwin
import EdithExtensionSupport
import Foundation

struct HostWorkerProcessGroups {
    private struct Ownership {
        let leader: ExtensionProcessIdentity
        var witnesses: [ExtensionProcessIdentity]
    }

    private var groups: [Int32: Ownership] = [:]
    private var worker: Ownership?
    private let maximumGroups: Int
    private let read: (Int32) -> ExtensionProcessIdentity?
    private let group: (Int32) -> Int32
    private let members: (Int32) -> [ExtensionProcessIdentity]
    private let signal: (Int32) -> Void

    var count: Int { groups.count }

    init(
        maximumGroups: Int = 128,
        read: @escaping (Int32) -> ExtensionProcessIdentity? = ExtensionProcessIdentity.read,
        group: @escaping (Int32) -> Int32 = { getpgid($0) },
        members: @escaping (Int32) -> [ExtensionProcessIdentity] = Self.members,
        signal: @escaping (Int32) -> Void = { kill($0, SIGKILL) }
    ) {
        self.maximumGroups = min(128, max(1, maximumGroups))
        self.read = read
        self.group = group
        self.members = members
        self.signal = signal
    }

    mutating func register(_ resource: HostWorkerProcessGroup, owner: Int32) throws {
        refresh(owner: owner)
        guard resource.pid > 1, resource.pid != getpid(),
            let identity = read(resource.pid), identity.generation == resource.generation
        else { throw HostWorkerError.invalidResponse }
        let currentGroup = group(resource.pid)
        guard currentGroup == resource.pid || currentGroup == owner else {
            throw HostWorkerError.invalidResponse
        }
        let ownership = Ownership(leader: identity, witnesses: [identity] + members(resource.pid))
        if resource.pid == owner {
            worker = ownership
            return
        }
        guard groups.count < maximumGroups || groups[resource.pid] != nil else {
            terminate(Ownership(leader: identity, witnesses: [identity]), owner: owner)
            throw HostWorkerError.invalidResponse
        }
        groups[resource.pid] = ownership
    }

    mutating func release(_ resource: HostWorkerProcessGroup, owner: Int32) {
        guard groups[resource.pid]?.leader.generation == resource.generation else { return }
        refresh(owner: owner)
    }

    mutating func refresh(owner: Int32) {
        worker = worker.flatMap { refreshed($0, owner: owner) }
        groups = groups.compactMapValues { refreshed($0, owner: owner) }
    }

    private func refreshed(_ ownership: Ownership, owner: Int32) -> Ownership? {
        let live = ownership.witnesses.filter {
            read($0.pid) == $0
                && (group($0.pid) == ownership.leader.pid
                    || ($0 == ownership.leader && group($0.pid) == owner))
        }
        guard !live.isEmpty else { return nil }
        return Ownership(
            leader: ownership.leader,
            witnesses: Array(
                Dictionary(
                    (live + members(ownership.leader.pid)).map { ($0.pid, $0) },
                    uniquingKeysWith: { first, _ in first }
                ).values.prefix(256)))
    }

    mutating func terminate(owner: Int32) {
        refresh(owner: owner)
        let owned = Array(groups.values) + (worker.map { [$0] } ?? [])
        groups.removeAll()
        worker = nil
        for ownership in owned { terminate(ownership, owner: owner) }
    }

    private func terminate(_ ownership: Ownership, owner: Int32) {
        let leader = ownership.leader
        if read(leader.pid) == leader, group(leader.pid) == owner {
            signal(leader.pid)
        }
        guard
            ownership.witnesses.contains(where: {
                read($0.pid) == $0 && group($0.pid) == leader.pid
            })
        else { return }
        signal(-leader.pid)
    }

    private static func members(_ group: Int32) -> [ExtensionProcessIdentity] {
        guard group > 1 else { return [] }
        var pids = [Int32](repeating: 0, count: 256)
        let count = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count) / MemoryLayout<Int32>.size).compactMap {
            ExtensionProcessIdentity.read($0)
        }
    }
}
