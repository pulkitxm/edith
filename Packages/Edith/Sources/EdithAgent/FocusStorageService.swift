import EdithCore
import EdithKit
import Foundation

public actor FocusStorageService {
    private let storage: FocusStorage

    public init(storage: FocusStorage = FocusStorage(root: AppDirectories.current.data)) {
        self.storage = storage
    }

    public func register(on runtime: AgentRuntime) async {
        await runtime.register(operation: AgentFocusStorageOperation.load) { _ in
            try await AgentPayload.encode(self.load())
        }
        await runtime.register(operation: AgentFocusStorageOperation.save) { payload in
            try await self.save(AgentPayload.decode(FocusDocument.self, from: payload))
            return Data()
        }
        await runtime.register(operation: AgentFocusStorageOperation.session) { _ in
            try await AgentPayload.encode(self.session())
        }
        await runtime.register(operation: AgentFocusStorageOperation.saveSession) { payload in
            try await self.saveSession(AgentPayload.decode(FocusSession?.self, from: payload))
            return Data()
        }
        await runtime.register(operation: AgentFocusStorageOperation.history) { _ in
            try await AgentPayload.encode(self.history())
        }
        await runtime.register(operation: AgentFocusStorageOperation.append) { payload in
            try await self.append(AgentPayload.decode(FocusHistoryRecord.self, from: payload))
            return Data()
        }
    }

    public func load() throws -> FocusDocument { try storage.load() }
    public func save(_ document: FocusDocument) throws { try storage.save(document) }
    public func session() throws -> FocusSession? { try storage.session() }
    public func saveSession(_ session: FocusSession?) throws { try storage.saveSession(session) }
    public func history() throws -> [FocusHistoryRecord] { try storage.history() }
    public func append(_ record: FocusHistoryRecord) throws { try storage.append(record) }
}
