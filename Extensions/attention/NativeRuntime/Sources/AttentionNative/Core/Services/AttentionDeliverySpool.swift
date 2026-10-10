@_implementationOnly import EdithExtensionSupport_attention_native
@_implementationOnly import EdithExtensionUI_attention_native
import Darwin
import Foundation

struct AttentionDeliveryRequest: Codable, Equatable, Sendable {
    let producerID: UUID
    let sequence: Int64
    let batch: AttentionBatch

    init(producerID: UUID, sequence: Int64, batch: AttentionBatch) {
        self.producerID = producerID
        self.sequence = sequence
        self.batch = batch
    }
}

struct AttentionDeliveryHealth: Codable, Equatable, Sendable {
    let pendingEvents: Int
    let committedSequence: Int64
    let rejectedEvents: Int64
    let rejectedDuration: TimeInterval
    let lastFailure: String?
}

final class AttentionDeliverySpool: @unchecked Sendable {
    static let maximumEvents = 4096
    static let maximumBytes = 4 << 20
    static var defaultFile: URL {
        AttentionPaths.root.appendingPathComponent("attention/delivery-spool.json")
    }

    private struct State: Codable, Sendable {
        var producerID = UUID()
        var nextSequence: Int64 = 1
        var pending: [AttentionDeliveryRequest] = []
        var rejectedEvents: Int64 = 0
        var rejectedDuration: TimeInterval = 0
        var lastFailure: String?
    }

    private let file: URL
    private let maximumEvents: Int
    private let maximumBytes: Int
    private let io = DispatchQueue(label: "edith.attention.delivery-spool", qos: .utility)
    private var state: State?

    init(
        file: URL = defaultFile, maximumEvents: Int = maximumEvents,
        maximumBytes: Int = maximumBytes
    ) {
        self.file = file
        self.maximumEvents = max(1, maximumEvents)
        self.maximumBytes = max(1024, maximumBytes)
    }

    func append(_ events: [AttentionEvent]) async throws -> Int {
        try await access(write: true) { state in
            var accepted = 0
            for event in events {
                guard event.duration.isFinite, event.duration > 0 else { continue }
                guard state.pending.count < self.maximumEvents,
                    state.nextSequence < Int64.max
                else {
                    Self.reject(event, state: &state)
                    continue
                }
                let request = AttentionDeliveryRequest(
                    producerID: state.producerID, sequence: state.nextSequence,
                    batch: AttentionBatch(events: [event]))
                state.pending.append(request)
                let bytes = try AttentionPayload.encode(state).count
                guard bytes <= self.maximumBytes - 512 else {
                    state.pending.removeLast()
                    Self.reject(event, state: &state)
                    continue
                }
                state.nextSequence += 1
                accepted += 1
            }
            return accepted
        }
    }

    func first() async throws -> AttentionDeliveryRequest? {
        try await access(write: false) { $0.pending.first }
    }

    func acknowledge(_ request: AttentionDeliveryRequest) async throws {
        try await access(write: true) { state in
            guard state.pending.first == request else {
                throw AttentionServiceError(
                    .refused, "Attention delivery acknowledgement is out of order.")
            }
            state.pending.removeFirst()
            state.lastFailure = nil
        }
    }

    func failedDelivery() async throws {
        try await access(write: true) {
            $0.lastFailure = "Attention delivery is unavailable. Saved events will retry."
        }
    }

    func recordOverflow(events: Int, duration: TimeInterval) async throws {
        try await access(write: true) { state in
            Self.reject(count: Int64(max(0, events)), duration: duration, state: &state)
        }
    }

    func health() async throws -> AttentionDeliveryHealth {
        try await access(write: false) { state in
            AttentionDeliveryHealth(
                pendingEvents: state.pending.count,
                committedSequence: (state.pending.first?.sequence ?? state.nextSequence) - 1,
                rejectedEvents: state.rejectedEvents,
                rejectedDuration: state.rejectedDuration, lastFailure: state.lastFailure)
        }
    }

    private static func reject(_ event: AttentionEvent, state: inout State) {
        reject(count: 1, duration: event.duration, state: &state)
    }

    private static func reject(count: Int64, duration: TimeInterval, state: inout State) {
        state.rejectedEvents += min(count, Int64.max - state.rejectedEvents)
        if duration.isFinite {
            state.rejectedDuration = min(1e15, state.rejectedDuration + max(0, duration))
        }
        state.lastFailure = "Attention delivery storage is full. New samples were not retained."
    }

    private func access<Value: Sendable>(
        write: Bool, _ operation: @escaping @Sendable (inout State) throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            io.async {
                do {
                    var next = try self.state ?? self.load()
                    let result = try operation(&next)
                    if write {
                        let data = try AttentionPayload.encode(next)
                        guard data.count <= self.maximumBytes else {
                            throw AttentionServiceError(
                                .refused, "Attention delivery storage exceeds its limit.")
                        }
                        try FileManager.default.createDirectory(
                            at: self.file.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        try self.checkFile()
                        try UsageDataFiles.write(data, to: self.file)
                    }
                    self.state = next
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func load() throws -> State {
        guard let data = try UsageDataFiles.readRegularFile(at: file, maximumBytes: maximumBytes)
        else { return State() }
        let value = try AttentionPayload.decode(State.self, from: data)
        guard value.pending.count <= maximumEvents, value.nextSequence > 0,
            value.rejectedEvents >= 0, value.rejectedDuration.isFinite,
            value.pending.allSatisfy({
                $0.producerID == value.producerID && $0.batch.events.count == 1
                    && $0.sequence > 0 && $0.sequence < value.nextSequence
            }),
            zip(value.pending, value.pending.dropFirst()).allSatisfy({
                $0.sequence + 1 == $1.sequence
            }),
            value.pending.last.map({ $0.sequence == value.nextSequence - 1 }) ?? true
        else {
            throw AttentionServiceError(
                .refused, "Attention delivery storage is invalid and was preserved.")
        }
        return value
    }

    private func checkFile() throws {
        var metadata = stat()
        if lstat(file.path, &metadata) != 0 {
            guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw AttentionServiceError(
                .refused, "Attention delivery storage must be a regular file.")
        }
    }
}
