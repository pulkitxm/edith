import DatabaseCore
import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import DatabaseExtension

@MainActor
final class DatabaseActionCase: HostedFunctionalActionCase {
    static let owner = "database"
    static let activationOperation = "database.ui.columns"
    private let transport: HostedFunctionalActionTransport
    private let client: DatabaseUIClient
    private let columns: DatabaseColumnsModel
    private static let connection = DatabaseConnectionID(rawValue:
        UUID(uuidString: "92000000-0000-4000-8000-000000000001")!)
    private static let object = DatabaseObjectIdentifier(kind: .table, path: ["public", "synthetic"])
    private static let fields = ["id", "name"].map { name in
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath(name), displayName: name, typeName: "TEXT",
            isNullable: false, isSortable: true, isFilterable: true)
    }

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        guard transport.context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        let client = DatabaseUIClient(engine: try transport.makeEngineClient())
        self.client = client
        columns = DatabaseColumnsModel(read: { client.columns }, write: { client.persistColumns($0) })
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        await client.load()
        guard client.loaded, client.failure == nil else { throw HostedFunctionalActionError.invalid }
        columns.synchronize(connectionID: Self.connection, object: Self.object, fields: Self.fields)
        try await client.flushColumns()
        columns.setWidth(238, for: Self.fields[1].path)
        try await client.flushColumns()
        let count = transport.originalInvocationCount
        columns.setWidth(274, for: Self.fields[1].path)
        try await client.flushColumns()
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let state = try JSONDecoder().decode(
            DatabaseUIState.self, from: await transport.readAuthoritative("database.ui.state"))
        guard let bytes = state.columns else { throw HostedFunctionalActionError.invalid }
        try DatabaseColumnsModel.validateStoredLayouts(bytes)
        let restored = DatabaseColumnsModel(read: { bytes }, write: { _ in })
        restored.synchronize(connectionID: Self.connection, object: Self.object, fields: Self.fields)
        guard restored.width(for: Self.fields[1].path) == 274, restored.allFieldsVisible else {
            throw HostedFunctionalActionError.invalid
        }
        return try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: bytes), options: [.sortedKeys])
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async {
        columns.clear()
        client.shutdown()
    }
}
