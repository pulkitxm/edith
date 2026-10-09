import EdithExtensionSupport
import Foundation

actor UsageMachinesProjection {
    struct Snapshot: Codable, Sendable {
        let machineID: UUID
        let collectionID: UUID
        let byteCount: Int
        let sha256: String
    }
    private struct Result: Codable, Sendable {
        let collectionID: UUID
        let offset: Int
        let maximumBytes: Int
    }
    private struct Cancel: Codable, Sendable { let collectionID: UUID }
    private struct Entry {
        let machine: Machine
        let peer: UsageMachinesPeer
        let data: Data
        let expires: Date
    }
    private struct Job {
        let machine: Machine
        let task: Task<Data, Error>
    }
    typealias Collector = @Sendable (URL, URL, UsageRemoteCollectionContext) async throws -> Data
    private let directory: URL
    private let currentPeer: @Sendable () async -> UsageMachinesPeer?
    private let currentMachine: @Sendable (UUID) async -> Machine?
    private let collector: Collector
    private let now: @Sendable () -> Date
    private var entries: [UUID: Entry] = [:]
    private var jobs: [UUID: Job] = [:]
    private var stopped = false
    private var forgetting: Set<UUID> = []
    private var generations: [UUID: UInt64] = [:]

    init(
        directory: URL = Repo.dataDir,
        currentPeer: @escaping @Sendable () async -> UsageMachinesPeer? = {
            await UsageMachinesPeer.current()
        },
        currentMachine: @escaping @Sendable (UUID) async -> Machine? = { id in
            await MainActor.run {
                MachineRegistry.machines().first { $0.id == id && $0.id != Machine.localID }
            }
        },
        now: @escaping @Sendable () -> Date = { Date() },
        collector: @escaping Collector = { home, archive, context in
            try await UsageNativeCollector.collectRemote(
                home: home, dataDirectory: archive,
                context: context, onEvent: { _ in })
        }
    ) {
        self.directory = directory; self.currentPeer = currentPeer
        self.currentMachine = currentMachine; self.now = now; self.collector = collector
    }

    func shutdown() async {
        stopped = true
        entries = [:]
        let pending = Array(jobs.values)
        for job in pending { job.task.cancel() }
        for job in pending { _ = try? await job.task.value }
        jobs = [:]
    }

    func forget(machineID: UUID) async throws {
        try Task.checkCancellation()
        guard !stopped, machineID != Machine.localID, !forgetting.contains(machineID),
            generations[machineID] != nil || generations.count < 128
        else { throw ExtensionPeerError.unavailable }
        forgetting.insert(machineID)
        generations[machineID, default: 0] &+= 1
        defer { forgetting.remove(machineID) }
        let pending = jobs.values.filter { $0.machine.id == machineID }
        for job in pending { job.task.cancel() }
        for job in pending { _ = try? await job.task.value }
        entries = entries.filter { $0.value.machine.id != machineID }
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try UsageMachinesPeer.forget(machineID: machineID, directory: directory)
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        entries = entries.filter { $0.value.expires > now() }
        switch command {
        case "usage.machines.project":
            let request = try decode(
                Snapshot.self, payload, keys: ["machineID", "collectionID", "byteCount", "sha256"])
            return try await project(request)
        case "usage.machines.result":
            let request = try decode(
                Result.self, payload, keys: ["collectionID", "offset", "maximumBytes"])
            guard let entry = entries[request.collectionID],
                request.offset >= 0, request.offset <= entry.data.count,
                (1...262_144).contains(request.maximumBytes)
            else { throw ExtensionPeerError.invalidRequest }
            guard await entry.peer.active(),
                await currentMachine(entry.machine.id) == entry.machine,
                !stopped, entry.expires > now(), entries[request.collectionID] != nil
            else {
                entries.removeValue(forKey: request.collectionID)
                throw ExtensionPeerError.unavailable
            }
            let end = min(entry.data.count, request.offset + request.maximumBytes)
            return try JSONEncoder().encode(
                UsageMachinesPeer.Chunk(
                    offset: request.offset,
                    data: entry.data.subdata(in: request.offset..<end),
                    finished: end == entry.data.count))
        case "usage.machines.cancel":
            let request = try decode(Cancel.self, payload, keys: ["collectionID"])
            if let job = jobs[request.collectionID] {
                job.task.cancel()
                _ = try? await job.task.value
                jobs.removeValue(forKey: request.collectionID)
            } else {
                guard entries.removeValue(forKey: request.collectionID) != nil else {
                    throw ExtensionPeerError.invalidRequest
                }
            }
            return Data("{}".utf8)
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    private func project(_ snapshot: Snapshot) async throws -> Data {
        let generation = generations[snapshot.machineID, default: 0]
        guard !forgetting.contains(snapshot.machineID),
            (1...67_108_864).contains(snapshot.byteCount), snapshot.sha256.utf8.count == 64,
            snapshot.sha256.allSatisfy({ $0.isHexDigit }), snapshot.machineID != Machine.localID,
            jobs[snapshot.collectionID] == nil, jobs.count + entries.count < 2,
            !jobs.values.contains(where: { $0.machine.id == snapshot.machineID }),
            let machine = await currentMachine(snapshot.machineID),
            let peer = await currentPeer(), await peer.active(), !stopped,
            !forgetting.contains(snapshot.machineID),
            generations[snapshot.machineID, default: 0] == generation,
            jobs[snapshot.collectionID] == nil, jobs.count + entries.count < 2,
            !jobs.values.contains(where: { $0.machine.id == snapshot.machineID })
        else { throw ExtensionPeerError.unavailable }
        try Task.checkCancellation()
        let directory = directory
        let collector = collector
        let currentMachine = currentMachine
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            var data = Data(); data.reserveCapacity(snapshot.byteCount)
            while data.count < snapshot.byteCount {
                try Task.checkCancellation()
                guard await peer.active(), await currentMachine(machine.id) == machine else {
                    throw ExtensionPeerError.unavailable
                }
                let raw = try await peer.invoke(
                    "machines.usage.snapshot.result",
                    JSONEncoder().encode(
                        Result(
                            collectionID: snapshot.collectionID,
                            offset: data.count, maximumBytes: 262_144)))
                guard raw.count <= 400_000 else { throw ExtensionPeerError.invalidRequest }
                let chunk = try JSONDecoder().decode(UsageMachinesPeer.Chunk.self, from: raw)
                guard chunk.offset == data.count, !chunk.data.isEmpty, chunk.data.count <= 262_144,
                    data.count + chunk.data.count <= snapshot.byteCount,
                    chunk.finished == (data.count + chunk.data.count == snapshot.byteCount)
                else { throw ExtensionPeerError.invalidRequest }
                data.append(chunk.data)
            }
            guard UsageMachinesPeer.hash(data) == snapshot.sha256.lowercased() else {
                throw ExtensionPeerError.invalidRequest
            }
            try UsageNativeFileIO.privateDirectory(directory)
            let stages = directory.appendingPathComponent("remote-staging", isDirectory: true)
            try UsageNativeFileIO.privateDirectory(stages)
            let home = stages.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let context = try Self.stage(data, machineID: snapshot.machineID, home: home)
            data.removeAll(keepingCapacity: false)
            try Task.checkCancellation()
            guard await peer.active(), await currentMachine(machine.id) == machine else {
                throw ExtensionPeerError.unavailable
            }
            let archives = directory.appendingPathComponent("remote-archives", isDirectory: true)
            try UsageNativeFileIO.privateDirectory(archives)
            let archive = archives.appendingPathComponent(
                machine.id.uuidString.lowercased(), isDirectory: true)
            try UsageNativeFileIO.privateDirectory(archive)
            let result = try await collector(home, archive, context)
            try Task.checkCancellation()
            guard result.count <= 67_108_864, UsageHistory.isValidDocument(result),
                await peer.active(), await currentMachine(machine.id) == machine
            else {
                throw ExtensionPeerError.invalidRequest
            }
            return result
        }
        jobs[snapshot.collectionID] = Job(machine: machine, task: task)
        defer { jobs.removeValue(forKey: snapshot.collectionID) }
        let data = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard !stopped, !forgetting.contains(snapshot.machineID),
            generations[snapshot.machineID, default: 0] == generation,
            await peer.active(), await currentMachine(machine.id) == machine,
            generations[snapshot.machineID, default: 0] == generation,
            jobs[snapshot.collectionID]?.task.isCancelled == false
        else { throw ExtensionPeerError.unavailable }
        let id = UUID()
        entries[id] = Entry(
            machine: machine, peer: peer, data: data, expires: now().addingTimeInterval(900))
        return try JSONEncoder().encode(
            UsageMachinesPeer.Receipt(
                collectionID: id,
                byteCount: data.count, sha256: UsageMachinesPeer.hash(data),
                generatedAt: ISO8601DateFormatter().string(from: now())))
    }

    private static func stage(_ data: Data, machineID: UUID, home: URL) throws
        -> UsageRemoteCollectionContext
    {
        let receipt = try UsageReceiptSnapshot.decode(data, machineID: machineID)
        try receipt.stage(at: home)
        return receipt.context
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, keys: Set<String>) throws -> T {
        guard data.count <= 16_384,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == keys
        else { throw ExtensionPeerError.invalidRequest }
        return try JSONDecoder().decode(type, from: data)
    }
}
