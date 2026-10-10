import CryptoKit
import EdithExtensionSupport
import Foundation

@MainActor public final class MachineUsageCollectionService {
    public typealias Collect = @MainActor (Machine, Bool) async throws -> Data
    public static let maximumDocumentBytes = 64 * 1_024 * 1_024
    public static let maximumChunkBytes = 262_144
    private struct Collection {
        let machine: Machine
        let expires: Date
        let document: Data
        let generatedAt: String
    }
    private let files: MachineRegistry.Files
    private let collect: Collect
    private let now: () -> Date
    private let lifetime: TimeInterval
    private var pending: [UUID: Task<Data, Error>] = [:]
    private var collections: [UUID: Collection] = [:]
    private struct ProgressJob {
        let machine: Machine
        var expires: Date
        let stream: MachineUsageProgress
        let task: Task<Void, Never>
    }
    private var progressJobs: [UUID: ProgressJob] = [:]
    private var reaper: Task<Void, Never>?
    private var stopped = false

    public init(
        files: MachineRegistry.Files = .init(), lifetime: TimeInterval = 300,
        now: @escaping () -> Date = Date.init, collect: @escaping Collect
    ) {
        self.files = files
        self.lifetime = min(900, max(1, lifetime))
        self.now = now
        self.collect = collect
    }

    public func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        prune()
        try Task.checkCancellation()
        switch command {
        case "machines.usage.start":
            let request = try MachineCommandPayload.decode(
                CollectRequest.self, data: payload, required: ["machineID", "force"])
            let machine = try selected(request.machineID)
            guard progressJobs.count < 2 else { throw ExtensionPeerError.unavailable }
            let id = UUID()
            let stream = MachineUsageProgress()
            let task = Task {
                do {
                    let receipt = try await MachineUsageProgressContext.$output.withValue({
                        line, error in
                        stream.receive(line, error: error)
                    }) {
                        try await self.execute("machines.usage.collect", payload: payload)
                    }
                    try Task.checkCancellation()
                    stream.finish(
                        receipt: try JSONDecoder().decode(
                            MachineUsageCollectionDescriptor.self, from: receipt))
                } catch {
                    stream.finish(error: error)
                }
            }
            stream.attach(task)
            progressJobs[id] = ProgressJob(
                machine: machine, expires: now().addingTimeInterval(60), stream: stream, task: task)
            ensureReaper()
            return try JSONEncoder().encode(CancelRequest(collectionID: id))
        case "machines.usage.progress":
            let request = try MachineCommandPayload.decode(
                ProgressRequest.self, data: payload, required: ["collectionID", "sequence"])
            guard var job = progressJobs[request.collectionID],
                try selected(job.machine.id) == job.machine
            else {
                throw ExtensionPeerError.invalidRequest
            }
            let frame = try job.stream.read(id: request.collectionID, sequence: request.sequence)
            job.expires = now().addingTimeInterval(60)
            progressJobs[request.collectionID] = job
            return try JSONEncoder().encode(frame)
        case "machines.usage.collect":
            let request = try MachineCommandPayload.decode(
                CollectRequest.self, data: payload, required: ["machineID", "force"])
            let machine = try selected(request.machineID)
            if !request.force,
                let cached = collections.first(where: { $0.value.machine == machine })
            {
                return try descriptor(id: cached.key, collection: cached.value)
            }
            guard pending.count < 2 else {
                throw ExtensionPeerError.rejected("A usage collection is already running.")
            }
            let id = UUID()
            let task = Task { try await collect(machine, request.force) }
            pending[id] = task
            defer { pending.removeValue(forKey: id) }
            let document = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard !stopped, pending[id] != nil, try selected(machine.id) == machine,
                document.count <= Self.maximumDocumentBytes,
                let object = try JSONSerialization.jsonObject(with: document) as? [String: Any],
                let schema = object["schemaVersion"] as? Int, schema == 8,
                let generatedAt = object["generatedAt"] as? String,
                Self.timestamp(generatedAt) != nil,
                object["sources"] is [String], object["daily"] is [Any],
                object["sessions"] is [Any], object["totals"] is [String: Any]
            else { throw ExtensionPeerError.invalidRequest }
            let collection = Collection(
                machine: machine, expires: now().addingTimeInterval(lifetime),
                document: document, generatedAt: generatedAt)
            collections = collections.filter { $0.value.machine.id != machine.id }
            if collections.count >= 2,
                let oldest = collections.min(by: { $0.value.expires < $1.value.expires })?.key
            {
                collections.removeValue(forKey: oldest)
            }
            collections[id] = collection
            return try descriptor(id: id, collection: collection)
        case "machines.usage.result":
            let request = try MachineCommandPayload.decode(
                ResultRequest.self, data: payload,
                required: ["collectionID", "offset", "maximumBytes"])
            guard let collection = collections[request.collectionID],
                try selected(collection.machine.id) == collection.machine,
                request.offset >= 0, request.offset <= collection.document.count,
                request.maximumBytes > 0, request.maximumBytes <= Self.maximumChunkBytes
            else { throw ExtensionPeerError.invalidRequest }
            let end = min(collection.document.count, request.offset + request.maximumBytes)
            return try JSONEncoder().encode(
                Chunk(
                    offset: request.offset,
                    data: collection.document.subdata(in: request.offset..<end),
                    finished: end == collection.document.count))
        case "machines.usage.cancel":
            let request = try MachineCommandPayload.decode(
                CancelRequest.self, data: payload, required: ["collectionID"])
            if let job = progressJobs[request.collectionID] {
                let receiptID = job.stream.receiptID
                job.stream.cancel()
                job.task.cancel()
                await job.task.value
                if let receiptID { collections.removeValue(forKey: receiptID) }
                progressJobs.removeValue(forKey: request.collectionID)
                return Data("{}".utf8)
            }
            guard pending[request.collectionID] != nil || collections[request.collectionID] != nil
            else {
                throw ExtensionPeerError.invalidRequest
            }
            if let task = pending[request.collectionID] {
                task.cancel()
                _ = try? await task.value
                pending.removeValue(forKey: request.collectionID)
            }
            collections.removeValue(forKey: request.collectionID)
            return Data("{}".utf8)
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    public func shutdown() {
        stopped = true
        reaper?.cancel(); reaper = nil
        for job in progressJobs.values { job.stream.cancel(); job.task.cancel() }
        for task in pending.values { task.cancel() }
        collections = [:]
    }

    public func shutdownAndWait() async {
        let tasks = Array(pending.values)
        let jobs = Array(progressJobs.values)
        shutdown()
        for task in tasks { _ = try? await task.value }
        for job in jobs { await job.task.value }
        progressJobs = [:]
    }

    private func ensureReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !self.stopped else { return }
                self.prune()
            }
        }
    }

    private func selected(_ id: UUID) throws -> Machine {
        let matches = MachineRegistry.machines(files).filter { $0.id == id }
        guard matches.count == 1, let machine = matches.first, MachineCommandPayload.valid(machine)
        else { throw ExtensionPeerError.invalidRequest }
        return machine
    }
    private func prune() {
        let instant = now()
        let machines = MachineRegistry.machines(files)
        for (id, job) in progressJobs {
            if job.expires <= instant
                || machines.filter({ $0.id == job.machine.id }) != [job.machine]
            {
                let receiptID = job.stream.receiptID
                job.stream.cancel(); job.task.cancel()
                if let receiptID { collections.removeValue(forKey: receiptID) }
                if job.stream.isFinished { progressJobs.removeValue(forKey: id) }
            }
        }
        collections = collections.filter { entry in
            entry.value.expires > instant
                && machines.filter { $0.id == entry.value.machine.id } == [entry.value.machine]
        }
    }
    private func descriptor(id: UUID, collection: Collection) throws -> Data {
        let hash = SHA256.hash(data: collection.document).map { String(format: "%02x", $0) }
            .joined()
        return try JSONEncoder().encode(
            MachineUsageCollectionDescriptor(
                collectionID: id, byteCount: collection.document.count,
                sha256: hash, generatedAt: collection.generatedAt))
    }
    private static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private struct CollectRequest: Decodable { let machineID: UUID; let force: Bool }
    private struct ResultRequest: Decodable {
        let collectionID: UUID; let offset: Int; let maximumBytes: Int
    }
    private struct ProgressRequest: Decodable { let collectionID: UUID; let sequence: UInt64 }
    private struct CancelRequest: Codable { let collectionID: UUID }
    private struct Chunk: Encodable { let offset: Int; let data: Data; let finished: Bool }
}
