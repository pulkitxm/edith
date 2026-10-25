import Foundation

@MainActor final class WorkerFixtureEngineRequestGate {
    private let identity = UUID()
    private let operations: [String]
    private let generation: String
    private var active: [UUID: WorkerFixtureEngineRequest] = [:]
    private var seen: Set<UUID> = []

    init(operations: [String], generation: String) {
        self.operations = operations; self.generation = generation
    }
    func begin(token: UUID, operation: String, payload: Data) throws -> WorkerFixtureEngineRequest {
        guard operations.contains(operation), active.count < 8, seen.count < 128,
            !seen.contains(token)
        else { throw WorkerFixtureError.invalid }
        _ = try WorkerFixtureJSON.object(payload)
        let request = WorkerFixtureEngineRequest(
            token: token, operation: operation,
            payloadSHA256: WorkerFixtureUIAdmission.digest(payload), generation: generation,
            admission: identity)
        seen.insert(token); active[token] = request
        return request
    }
    func contains(_ request: WorkerFixtureEngineRequest) -> Bool {
        request.admission == identity && active[request.token] == request
            && request.generation == generation
    }
    func complete(_ request: WorkerFixtureEngineRequest) throws {
        guard contains(request) else { throw WorkerFixtureError.invalid }
        active[request.token] = nil
    }
    func cancel(_ request: WorkerFixtureEngineRequest) {
        if contains(request) { active[request.token] = nil }
    }
}
