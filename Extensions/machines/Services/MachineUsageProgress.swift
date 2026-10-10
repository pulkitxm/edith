import EdithExtensionSupport
import Foundation

enum MachineUsageProgressContext {
    @TaskLocal static var output: (@Sendable (String, Bool) -> Void)?
}

struct MachineUsageCollectionDescriptor: Codable, Sendable {
    let collectionID: UUID
    let byteCount: Int
    let sha256: String
    let generatedAt: String
}

final class MachineUsageProgress: @unchecked Sendable {
    enum State: String, Codable { case running, completed, cancelled, overflow, failed }
    struct Chunk: Codable {
        let sequence: UInt64
        let channel: String
        let data: Data
    }
    struct Frame: Codable {
        let collectionID: UUID
        let sequence: UInt64
        let nextSequence: UInt64
        let chunks: [Chunk]
        let state: State
        let receipt: MachineUsageCollectionDescriptor?
        let error: String?
    }
    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var bytes = 0
    private var nextSequence: UInt64 = 0
    private var readSequence: UInt64 = 0
    private var state = State.running
    private var receipt: MachineUsageCollectionDescriptor?
    private var failure: String?
    private var finished = false
    private var task: Task<Void, Never>?

    var receiptID: UUID? { lock.withLock { receipt?.collectionID } }

    var isFinished: Bool { lock.withLock { finished } }

    func attach(_ task: Task<Void, Never>) {
        let cancel = lock.withLock {
            self.task = task
            return state != .running
        }
        if cancel { task.cancel() }
    }

    func receive(_ line: String, error: Bool) {
        let data = Data((line + "\n").utf8)
        let cancel = lock.withLock { () -> Task<Void, Never>? in
            guard state == .running else { return nil }
            let count = (data.count + 65_535) / 65_536
            guard bytes + data.count <= 1_048_576, chunks.count + count <= 4096 else {
                state = .overflow
                failure = "Collector output exceeded its bounded unread capacity."
                return task
            }
            for offset in stride(from: 0, to: data.count, by: 65_536) {
                let part = data.subdata(in: offset..<min(data.count, offset + 65_536))
                chunks.append(
                    Chunk(sequence: nextSequence, channel: error ? "stderr" : "stdout", data: part))
                nextSequence += 1
            }
            bytes += data.count
            return nil
        }
        cancel?.cancel()
    }

    func finish(receipt: MachineUsageCollectionDescriptor? = nil, error: Error? = nil) {
        lock.withLock {
            finished = true
            task = nil
            guard state == .running else { return }
            self.receipt = receipt
            if let error {
                state = error is CancellationError ? .cancelled : .failed
                failure = String(
                    decoding: error.localizedDescription.utf8.prefix(4096), as: UTF8.self)
            } else {
                state = .completed
            }
        }
    }

    func cancel() {
        let task = lock.withLock {
            state = .cancelled
            chunks = []; bytes = 0
            receipt = nil
            return task
        }
        task?.cancel()
    }

    func read(id: UUID, sequence: UInt64) throws -> Frame {
        try lock.withLock {
            guard sequence == readSequence else { throw ExtensionPeerError.invalidRequest }
            var count = 0
            var size = 0
            while count < min(64, chunks.count), size + chunks[count].data.count <= 262_144 {
                size += chunks[count].data.count
                count += 1
            }
            let delivered = Array(chunks.prefix(count))
            chunks.removeFirst(count)
            bytes -= size
            readSequence = delivered.last.map { $0.sequence + 1 } ?? readSequence
            let visibleState = chunks.isEmpty ? state : .running
            return Frame(
                collectionID: id, sequence: sequence, nextSequence: readSequence,
                chunks: delivered, state: visibleState,
                receipt: visibleState == .completed ? receipt : nil,
                error: visibleState == .running ? nil : failure)
        }
    }
}
