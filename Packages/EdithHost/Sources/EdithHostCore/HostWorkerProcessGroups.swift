import Darwin
import EdithExtensionSupport
import Foundation

struct HostWorkerProcessGroups {
    private struct Ownership {
        let leader: ExtensionProcessIdentity
        var witnesses: [ExtensionProcessIdentity]
        var processGroups: Set<Int32>

        init(
            leader: ExtensionProcessIdentity, witnesses: [ExtensionProcessIdentity],
            processGroups: Set<Int32>
        ) {
            self.leader = leader
            self.processGroups = processGroups
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
    private let groupPresence: (Int32) -> Bool?
    private let signal: (Int32) -> Void
    private let descendant: (Int32, Int32) -> Bool
    private let descendants: (Int32) -> [ExtensionProcessIdentity]

    var count: Int { groups.count }
    var isEmpty: Bool { groups.isEmpty && worker == nil }

    init(
        maximumGroups: Int = 128,
        read: @escaping (Int32) -> ExtensionProcessIdentity? = ExtensionProcessIdentity.read,
        group: @escaping (Int32) -> Int32 = { getpgid($0) },
        members: ((Int32) -> [ExtensionProcessIdentity])? = nil,
        groupPresence: ((Int32) -> Bool?)? = nil,
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
        self.members = members ?? Self.members
        self.groupPresence =
            groupPresence ?? members.map { members in { !members($0).isEmpty } }
            ?? Self.groupPresence
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
        let currentGroup = group(identity.pid)
        worker = Ownership(
            leader: identity, witnesses: [identity] + descendants(identity.pid),
            processGroups: currentGroup > 1 && currentGroup != getpgrp() ? [currentGroup] : [])
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
        let ownership = Ownership(
            leader: identity, witnesses: [identity] + members(currentGroup),
            processGroups: currentGroup != getpgrp() ? [currentGroup] : [])
        if resource.pid == owner {
            worker = Ownership(
                leader: identity, witnesses: ownership.witnesses + (worker?.witnesses ?? []),
                processGroups: ownership.processGroups.union(worker?.processGroups ?? []))
            return
        }
        let admitted = groups.count < maximumGroups || groups[resource.pid] != nil
        groups[resource.pid] = Ownership(
            leader: identity,
            witnesses: ownership.witnesses + (groups[resource.pid]?.witnesses ?? []),
            processGroups: ownership.processGroups.union(groups[resource.pid]?.processGroups ?? []))
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
        var processGroups = ownership.processGroups
        for witness in live where read(witness.pid) == witness {
            let currentGroup = group(witness.pid)
            if currentGroup > 1, currentGroup != getpgrp() { processGroups.insert(currentGroup) }
        }
        let children = live.filter { read($0.pid) == $0 }.flatMap { descendants($0.pid) }
        for child in children where read(child.pid) == child {
            let currentGroup = group(child.pid)
            if currentGroup > 1, currentGroup != getpgrp() { processGroups.insert(currentGroup) }
        }
        var groupMembers: [ExtensionProcessIdentity] = []
        for ownedGroup in processGroups {
            if (live + children).contains(where: {
                read($0.pid) == $0 && group($0.pid) == ownedGroup
            }) {
                groupMembers += members(ownedGroup)
            }
        }
        processGroups = processGroups.filter { groupPresence($0) != false }
        guard !live.isEmpty || !children.isEmpty || !processGroups.isEmpty else { return nil }
        return Ownership(
            leader: ownership.leader,
            witnesses: live + groupMembers + children, processGroups: processGroups)
    }

    mutating func terminate(owner: Int32) {
        refresh(owner: owner)
        let owned = Array(groups.values) + (worker.map { [$0] } ?? [])
        for ownership in owned { terminate(ownership, owner: owner) }
    }

    mutating func terminateCaptured(_ identity: ExtensionProcessIdentity) {
        sendSignal(identity.pid, witness: identity)
    }

    private mutating func sendSignal(_ target: Int32, witness: ExtensionProcessIdentity) {
        guard read(witness.pid) == witness,
            target > 0 || group(witness.pid) == -target
        else { return }
        signal(target)
    }

    private mutating func terminate(_ ownership: Ownership, owner: Int32) {
        for ownedGroup in ownership.processGroups.sorted() {
            if let witness = ownership.witnesses.first(where: {
                read($0.pid) == $0 && group($0.pid) == ownedGroup
            }) {
                sendSignal(-ownedGroup, witness: witness)
            }
        }
        for witness in ownership.witnesses where read(witness.pid) == witness {
            sendSignal(witness.pid, witness: witness)
        }
    }

    private static func processIDs(_ type: UInt32, _ value: UInt32) throws -> [Int32] {
        errno = 0
        let size = proc_listpids(type, value, nil, 0)
        guard size >= 0, size != 0 || errno == 0, size <= 4_000_000 else {
            throw HostWorkerError.invalidResponse
        }
        var pids = [Int32](repeating: 0, count: Int(size) / MemoryLayout<Int32>.size + 256)
        errno = 0
        let count = pids.withUnsafeMutableBytes {
            proc_listpids(type, value, $0.baseAddress, Int32($0.count))
        }
        guard count >= 0, count != 0 || errno == 0,
            Int(count) < pids.count * MemoryLayout<Int32>.size
        else { throw HostWorkerError.invalidResponse }
        return pids.prefix(Int(count) / MemoryLayout<Int32>.size).filter { $0 > 1 }
    }

    private static func groupPresence(_ group: Int32) -> Bool? {
        guard group > 1 else { return false }
        return (try? processIDs(UInt32(PROC_PGRP_ONLY), UInt32(group))).map { !$0.isEmpty }
    }

    private static func members(_ group: Int32) -> [ExtensionProcessIdentity] {
        guard group > 1 else { return [] }
        return ((try? processIDs(UInt32(PROC_PGRP_ONLY), UInt32(group))) ?? []).compactMap {
            ExtensionProcessIdentity.read($0)
        }
    }

    private static func descendants(_ owner: Int32) -> [ExtensionProcessIdentity] {
        guard let root = ExtensionProcessIdentity.read(owner) else { return [] }
        var parents = [root]
        var observed = Set([owner])
        var children: [ExtensionProcessIdentity] = []
        for _ in 0..<16 {
            var next: [ExtensionProcessIdentity] = []
            for parent in parents where parent.isAlive {
                let pids = (try? processIDs(UInt32(PROC_PPID_ONLY), UInt32(parent.pid))) ?? []
                for pid in pids where !observed.contains(pid) {
                    guard parent.isAlive, let child = ExtensionProcessIdentity.read(pid),
                        ExtensionNativeTask.isDescendant(pid, of: parent.pid), parent.isAlive,
                        child.isAlive
                    else { continue }
                    observed.insert(pid)
                    children.append(child)
                    next.append(child)
                }
            }
            guard !next.isEmpty else { break }
            parents = next
        }
        return children
    }
}
