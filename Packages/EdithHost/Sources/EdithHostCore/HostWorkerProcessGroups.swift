import Darwin
import EdithExtensionSupport
import Foundation

struct HostWorkerProcessGroups {
    private struct Ownership {
        let leader: ExtensionProcessIdentity
        var witnesses: [ExtensionProcessIdentity]

        init(leader: ExtensionProcessIdentity, witnesses: [ExtensionProcessIdentity]) {
            self.leader = leader
            self.witnesses = Array(
                Dictionary(
                    witnesses.map { ($0.pid, $0) },
                    uniquingKeysWith: { first, _ in first }
                ).values)
        }
    }

    private var groups: [Int32: Ownership] = [:]
    private var worker: Ownership?
    private let maximumGroups: Int
    private let read: (Int32) -> ExtensionProcessIdentity?
    private let exists: (Int32) -> Bool
    private let group: (Int32) -> Int32
    private let members: (Int32) -> [ExtensionProcessIdentity]
    private let signal: (Int32) -> Void
    private let descendant: (Int32, Int32) -> Bool
    private let descendants: (Int32) -> [ExtensionProcessIdentity]

    var count: Int { groups.count }
    var isEmpty: Bool { groups.isEmpty && worker == nil }

    init(
        maximumGroups: Int = 128,
        read: @escaping (Int32) -> ExtensionProcessIdentity? = ExtensionProcessIdentity.read,
        group: @escaping (Int32) -> Int32 = { getpgid($0) },
        members: @escaping (Int32) -> [ExtensionProcessIdentity] = Self.members,
        signal: @escaping (Int32) -> Void = { kill($0, SIGKILL) },
        descendant: @escaping (Int32, Int32) -> Bool = {
            ExtensionNativeTask.isDescendant($0, of: $1)
        },
        descendants: @escaping (Int32) -> [ExtensionProcessIdentity] = Self.descendants,
        exists: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno != ESRCH }
    ) {
        self.maximumGroups = min(128, max(1, maximumGroups))
        self.read = read
        self.exists = exists
        self.group = group
        self.members = members
        self.signal = signal
        self.descendant = descendant
        self.descendants = descendants
    }

    mutating func captureAuthenticatedWorker(pid: Int32, generation: String) throws {
        let fields = generation.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, let seconds = UInt64(fields[0]),
            let microseconds = UInt64(fields[1]), microseconds < 1_000_000,
            generation == "\(seconds):\(microseconds)",
            let birth = read(pid), birth.generation == "\(seconds).\(microseconds)"
        else { throw HostWorkerError.invalidResponse }
        try captureWorker(birth)
    }

    mutating func captureWorker(_ identity: ExtensionProcessIdentity) throws {
        guard read(identity.pid) == identity else { throw HostWorkerError.invalidResponse }
        worker = Ownership(leader: identity, witnesses: [identity] + descendants(identity.pid))
    }

    mutating func register(_ resource: HostWorkerProcessGroup, owner: Int32) throws {
        refresh(owner: owner)
        guard resource.pid > 1, resource.pid != getpid(),
            let identity = read(resource.pid), identity.generation == resource.generation,
            resource.pid == owner || descendant(resource.pid, owner)
        else { throw HostWorkerError.invalidResponse }
        let currentGroup = group(resource.pid)
        guard currentGroup == resource.pid || currentGroup == owner else {
            throw HostWorkerError.invalidResponse
        }
        let ownership = Ownership(leader: identity, witnesses: [identity] + members(resource.pid))
        if resource.pid == owner {
            worker = Ownership(
                leader: identity, witnesses: ownership.witnesses + (worker?.witnesses ?? []))
            return
        }
        let admitted = groups.count < maximumGroups || groups[resource.pid] != nil
        groups[resource.pid] = Ownership(
            leader: identity,
            witnesses: ownership.witnesses + (groups[resource.pid]?.witnesses ?? []))
        guard admitted else {
            terminate(ownership, owner: owner)
            throw HostWorkerError.invalidResponse
        }
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
            let identity = read($0.pid)
            return identity == $0 || (identity == nil && exists($0.pid))
        }
        guard !live.isEmpty else { return nil }
        let groupMembers =
            live.contains { read($0.pid) == $0 && group($0.pid) == ownership.leader.pid }
            ? members(ownership.leader.pid) : []
        let children = live.filter { read($0.pid) == $0 }.flatMap { descendants($0.pid) }
        return Ownership(
            leader: ownership.leader,
            witnesses: Array(
                Dictionary(
                    (live + groupMembers + children).map { ($0.pid, $0) },
                    uniquingKeysWith: { first, _ in first }
                ).values))
    }

    mutating func terminate(owner: Int32) {
        refresh(owner: owner)
        let owned = Array(groups.values) + (worker.map { [$0] } ?? [])
        for ownership in owned { terminate(ownership, owner: owner) }
    }

    private func terminate(_ ownership: Ownership, owner: Int32) {
        let leader = ownership.leader
        if ownership.witnesses.contains(where: {
            read($0.pid) == $0 && group($0.pid) == leader.pid
        }) {
            signal(-leader.pid)
        }
        for witness in ownership.witnesses where read(witness.pid) == witness {
            signal(witness.pid)
        }
    }

    private static func processIDs(_ type: UInt32, _ value: UInt32) -> [Int32] {
        let size = proc_listpids(type, value, nil, 0)
        guard size > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(size) / MemoryLayout<Int32>.size + 256)
        let count = pids.withUnsafeMutableBytes {
            proc_listpids(type, value, $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count) / MemoryLayout<Int32>.size))
    }

    private static func members(_ group: Int32) -> [ExtensionProcessIdentity] {
        guard group > 1 else { return [] }
        return processIDs(UInt32(PROC_PGRP_ONLY), UInt32(group)).compactMap {
            ExtensionProcessIdentity.read($0)
        }
    }

    private static func descendants(_ owner: Int32) -> [ExtensionProcessIdentity] {
        processIDs(UInt32(PROC_ALL_PIDS), 0).filter {
            ExtensionNativeTask.isDescendant($0, of: owner)
        }.compactMap { ExtensionProcessIdentity.read($0) }
    }
}
