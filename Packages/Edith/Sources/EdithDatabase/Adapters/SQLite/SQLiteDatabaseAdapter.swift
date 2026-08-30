import Foundation
import GRDB

struct SQLiteDatabaseAdapter: DatabaseAdapter {
    let id: DatabaseAdapterID = "sqlite"
    let products: Set<DatabaseProduct> = [.sqlite]

    func connect(
        _ connection: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterSession {
        try await SQLiteDatabaseAdapterSupport.check(context)
        let plan = try SQLiteDatabaseAdapterSupport.validate(connection)
        try await SQLiteDatabaseAdapterSupport.check(context)

        var databaseQueue: DatabaseQueue?
        var connected = false
        defer {
            if !connected {
                databaseQueue?.interrupt()
                try? databaseQueue?.close()
            }
        }

        do {
            databaseQueue = try SQLiteDatabaseAdapterSupport.open(
                plan,
                connection: connection.definition)
            guard let databaseQueue else {
                throw SQLiteDatabaseAdapterSupport.connectionFailed
            }
            if case let .file(file) = plan {
                try SQLiteDatabaseAdapterSupport.validateOpenedFile(file)
            }
            let identity = try SQLiteDatabaseAdapterSupport.discoverIdentity(databaseQueue)
            try await SQLiteDatabaseAdapterSupport.check(context)
            connected = true
            return SQLiteDatabaseAdapterSession(
                connection: connection.definition,
                productIdentity: identity,
                databaseQueue: databaseQueue)
        } catch let failure as DatabaseAdapterFailure {
            throw failure
        } catch {
            throw SQLiteDatabaseAdapterSupport.connectionFailed
        }
    }
}

actor SQLiteDatabaseAdapterSession: DatabaseAdapterSession {
    nonisolated let id = DatabaseAdapterSessionID()
    nonisolated let connection: DatabaseConnectionDefinition
    nonisolated let productIdentity: DatabaseProductIdentity

    private var databaseQueue: DatabaseQueue?
    private var state: DatabaseAdapterSessionState = .connected

    init(
        connection: DatabaseConnectionDefinition,
        productIdentity: DatabaseProductIdentity,
        databaseQueue: DatabaseQueue
    ) {
        self.connection = connection
        self.productIdentity = productIdentity
        self.databaseQueue = databaseQueue
    }

    func lifecycleState() -> DatabaseAdapterSessionState {
        state
    }

    func discoverCapabilities(
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseCapabilityReport {
        try await SQLiteDatabaseAdapterSupport.check(context)
        let databaseQueue = try connectedDatabase()
        do {
            let discoveredIdentity = try SQLiteDatabaseAdapterSupport.discoverIdentity(
                databaseQueue)
            guard discoveredIdentity == productIdentity else {
                failAndClose()
                throw SQLiteDatabaseAdapterSupport.connectionFailed
            }
        } catch let failure as DatabaseAdapterFailure {
            throw failure
        } catch {
            failAndClose()
            throw SQLiteDatabaseAdapterSupport.connectionFailed
        }
        try await SQLiteDatabaseAdapterSupport.check(context)
        let report = SQLiteDatabaseAdapterSupport.capabilityReport(
            identity: productIdentity)
        try DatabaseAdapterBounds.validate(report: report, identity: productIdentity)
        return report
    }

    func readPage(
        _ request: DatabaseAdapterPageRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        try await requireAvailableContext(context)
        throw SQLiteDatabaseAdapterSupport.capabilityUnavailable
    }

    func query(
        _ request: DatabaseAdapterQueryRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        try await requireAvailableContext(context)
        throw SQLiteDatabaseAdapterSupport.capabilityUnavailable
    }

    func normalizeMutation(
        _ request: DatabaseDestructiveRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        try await requireAvailableContext(context)
        throw SQLiteDatabaseAdapterSupport.capabilityUnavailable
    }

    func executeMutation(
        _ plan: DatabaseDestructivePlan,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationResult {
        try await requireAvailableContext(context)
        throw SQLiteDatabaseAdapterSupport.capabilityUnavailable
    }

    func openStream(
        _ request: DatabaseAdapterStreamRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterRecordStream {
        try await requireAvailableContext(context)
        throw SQLiteDatabaseAdapterSupport.capabilityUnavailable
    }

    func cancel(_ operationID: DatabaseOperationID) -> DatabaseAdapterCancellationResult {
        DatabaseAdapterCancellationResult(
            support: .unavailable,
            disposition: .unavailable)
    }

    func disconnect() {
        guard state == .connected || state == .failed else { return }
        state = .disconnecting
        databaseQueue?.interrupt()
        try? databaseQueue?.close()
        databaseQueue = nil
        state = .disconnected
    }

    func resourceIsOpen() -> Bool {
        databaseQueue != nil
    }

    func readOnlyEnforcementIsActive() -> Bool {
        guard let databaseQueue else { return false }
        if databaseQueue.configuration.readonly {
            return true
        }
        return
            (try? databaseQueue.unsafeRead { database in
                try Int.fetchOne(database, sql: "PRAGMA query_only") == 1
            }) == true
    }

    private func connectedDatabase() throws(DatabaseAdapterFailure) -> DatabaseQueue {
        guard state == .connected, let databaseQueue else {
            throw SQLiteDatabaseAdapterSupport.disconnected
        }
        return databaseQueue
    }

    private func requireAvailableContext(
        _ context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) {
        try await SQLiteDatabaseAdapterSupport.check(context)
        _ = try connectedDatabase()
        try await SQLiteDatabaseAdapterSupport.check(context)
    }

    private func failAndClose() {
        databaseQueue?.interrupt()
        try? databaseQueue?.close()
        databaseQueue = nil
        state = .failed
    }
}

private enum SQLiteDatabaseAdapterConnectionPlan: Sendable {
    case file(SQLiteDatabaseAdapterFilePlan)
    case memory(name: String?, enforceReadOnly: Bool)
}

private struct SQLiteDatabaseAdapterFilePlan: Sendable {
    let path: String
    let mode: SQLiteDatabaseAdapterFileMode
    let enforceQueryOnly: Bool
    let identity: SQLiteDatabaseAdapterFileIdentity?
}

private enum SQLiteDatabaseAdapterFileMode: String, Sendable {
    case readOnly = "ro"
    case readWrite = "rw"
    case readWriteCreate = "rwc"
}

private struct SQLiteDatabaseAdapterFileIdentity: Equatable, Sendable {
    let systemNumber: UInt64
    let fileNumber: UInt64
}

private enum SQLiteDatabaseAdapterSupport {
    static let connectionFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .connectionFailed,
            message: "The SQLite database could not be opened.",
            productCode: "sqlite.open_failed",
            retry: DatabaseRetryGuidance(action: .none)))

    static let disconnected = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .connectionFailed,
            message: "The SQLite session is disconnected.",
            productCode: "sqlite.session.disconnected",
            retry: DatabaseRetryGuidance(action: .reconnect)))

    static let capabilityUnavailable = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .unsupported,
            message: "The requested SQLite capability is unavailable.",
            productCode: "sqlite.capability.not_implemented",
            retry: DatabaseRetryGuidance(action: .none)))

    private static let invalidConnection = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The SQLite connection configuration is invalid.",
            productCode: "sqlite.connection.invalid",
            retry: DatabaseRetryGuidance(action: .none)))

    private static let bookmarkUnavailable = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .unsupported,
            message: "SQLite file bookmarks are not supported by this adapter.",
            productCode: "sqlite.file_bookmark.unavailable",
            retry: DatabaseRetryGuidance(action: .none)))

    private static let deadlineExceeded = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .timeout,
            message: "The database operation deadline was exceeded.",
            productCode: "sqlite.deadline_exceeded",
            retry: DatabaseRetryGuidance(action: .none)))

    static func check(
        _ context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) {
        try await context.checkCancellation()
        guard let deadline = context.deadline else { return }
        guard deadline.timeIntervalSinceReferenceDate.isFinite, deadline > Date() else {
            throw deadlineExceeded
        }
    }

    static func validate(
        _ connection: DatabaseResolvedConnection
    ) throws(DatabaseAdapterFailure) -> SQLiteDatabaseAdapterConnectionPlan {
        let definition = connection.definition
        guard definition.version == DatabaseConnectionDefinition.schemaVersion,
            definition.productHint == .sqlite,
            definition.username == nil,
            definition.authentication.kind == .none,
            definition.authentication.secretReferences.isEmpty,
            definition.authentication.source == nil,
            connection.secrets.isEmpty,
            definition.tls.mode == .disabled,
            definition.tls.verification == .none,
            definition.tls.serverName == nil,
            definition.tls.certificateAuthority == nil,
            definition.tls.clientCertificate == nil,
            definition.tls.clientPrivateKey == nil,
            definition.tunnel == nil,
            definition.options.isEmpty
        else {
            throw invalidConnection
        }
        guard definition.deploymentMode == .automatic || definition.deploymentMode == .embedded
        else {
            throw invalidConnection
        }

        let policyReadOnly =
            definition.readOnlyPolicy != .disabled
            || definition.environment.protection == .readOnly
        switch definition.location {
        case let .sqlite(location):
            guard location.fileReference == nil else {
                throw bookmarkUnavailable
            }
            return .file(
                try filePlan(
                    location,
                    policyReadOnly: policyReadOnly))
        case let .memory(name):
            try validateMemoryName(name)
            return .memory(name: name, enforceReadOnly: policyReadOnly)
        case .network:
            throw invalidConnection
        }
    }

    static func open(
        _ plan: SQLiteDatabaseAdapterConnectionPlan,
        connection: DatabaseConnectionDefinition
    ) throws -> DatabaseQueue {
        switch plan {
        case let .file(file):
            let configuration = configuration(
                connection: connection,
                readOnly: file.mode == .readOnly,
                enforceQueryOnly: file.enforceQueryOnly)
            return try DatabaseQueue(
                path: try fileURI(path: file.path, mode: file.mode),
                configuration: configuration)
        case let .memory(name, enforceReadOnly):
            let configuration = configuration(
                connection: connection,
                readOnly: false,
                enforceQueryOnly: enforceReadOnly)
            return try DatabaseQueue(named: name, configuration: configuration)
        }
    }

    static func discoverIdentity(
        _ databaseQueue: DatabaseQueue
    ) throws -> DatabaseProductIdentity {
        let versionString = try databaseQueue.unsafeRead { database in
            try String.fetchOne(database, sql: "SELECT sqlite_version()")
        }
        guard let versionString, !versionString.isEmpty else {
            throw connectionFailed
        }
        let components = versionString.split(separator: ".", omittingEmptySubsequences: false)
        return DatabaseProductIdentity(
            product: .sqlite,
            version: DatabaseVersion(
                string: versionString,
                major: components.indices.contains(0) ? Int(components[0]) : nil,
                minor: components.indices.contains(1) ? Int(components[1]) : nil,
                patch: components.indices.contains(2) ? Int(components[2]) : nil),
            distribution: "SQLite",
            topology: DatabaseTopology(
                kind: .embedded,
                localRole: "embedded",
                nodeCount: 1))
    }

    static func capabilityReport(
        identity: DatabaseProductIdentity
    ) -> DatabaseCapabilityReport {
        let unavailableReason = DatabaseCapabilityUnavailableReason(
            category: .notImplemented,
            message: "This capability is not implemented by the SQLite adapter.")
        let unavailable: [(DatabaseCapabilityID, DatabaseCapabilityRequirement)] = [
            (.objectDiscovery, .sharedRequired),
            (.objectDescription, .familyRequired),
            (.query, .familyRequired),
            (.queryCancellation, .sharedRequired),
            (.explain, .familyRequired),
            (.browse, .sharedRequired),
            (.insert, .sharedRequired),
            (.update, .sharedRequired),
            (.delete, .sharedRequired),
            (.bulkMutation, .sharedRequired),
            (.importData, .sharedRequired),
            (.exportData, .sharedRequired),
            (.transactions, .familyRequired),
            (.schemaMutation, .productRequired),
            (.monitoring, .productRequired),
            (.administration, .productRequired),
        ]
        let capabilities =
            [
                DatabaseCapabilityStatus(
                    id: .connectionTest,
                    requirement: .sharedRequired,
                    availability: .available)
            ]
            + unavailable.map { identifier, requirement in
                DatabaseCapabilityStatus(
                    id: identifier,
                    requirement: requirement,
                    availability: .unavailable,
                    reason: unavailableReason)
            }
        return DatabaseCapabilityReport(
            productIdentity: identity,
            capabilities: capabilities,
            mutationModes: [.unsupported],
            transactionModes: [.none],
            cancellationModes: [.cooperative],
            safetyLimitations: [
                "Data browsing, querying, streaming, and mutation are not implemented."
            ],
            discoveredAt: Date())
    }

    static func validateOpenedFile(
        _ plan: SQLiteDatabaseAdapterFilePlan
    ) throws(DatabaseAdapterFailure) {
        guard !isSymbolicLink(at: plan.path),
            let attributes = regularFileAttributes(at: plan.path)
        else {
            throw invalidConnection
        }
        if let expectedIdentity = plan.identity {
            guard fileIdentity(attributes) == expectedIdentity else {
                throw invalidConnection
            }
        }
    }

    private static func filePlan(
        _ location: DatabaseSQLiteLocation,
        policyReadOnly: Bool
    ) throws(DatabaseAdapterFailure) -> SQLiteDatabaseAdapterFilePlan {
        let path = location.path
        guard !path.isEmpty,
            path.utf8.count <= 4_096,
            !path.contains("\0"),
            path.hasPrefix("/"),
            URL(fileURLWithPath: path).standardizedFileURL.path == path,
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            !isSymbolicLink(at: path)
        else {
            throw invalidConnection
        }

        let originalURL = URL(fileURLWithPath: path)
        let resolvedParent = originalURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var parentIsDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: resolvedParent.path,
                isDirectory: &parentIsDirectory),
            parentIsDirectory.boolValue
        else {
            throw invalidConnection
        }
        let canonicalURL = resolvedParent.appendingPathComponent(
            originalURL.lastPathComponent,
            isDirectory: false)
        let canonicalPath = canonicalURL.path
        guard canonicalURL.deletingLastPathComponent().path == resolvedParent.path,
            !isSymbolicLink(at: canonicalPath)
        else {
            throw invalidConnection
        }

        var isDirectory: ObjCBool = false
        let existed = FileManager.default.fileExists(
            atPath: canonicalPath,
            isDirectory: &isDirectory)
        guard !existed || !isDirectory.boolValue else {
            throw invalidConnection
        }
        if location.accessMode != .createIfMissing, !existed {
            throw connectionFailed
        }
        let identity: SQLiteDatabaseAdapterFileIdentity?
        if existed {
            guard let attributes = regularFileAttributes(at: canonicalPath),
                let existingIdentity = fileIdentity(attributes)
            else {
                throw invalidConnection
            }
            identity = existingIdentity
        } else {
            identity = nil
        }

        let effectiveReadOnly = location.accessMode == .readOnly || policyReadOnly
        let mode: SQLiteDatabaseAdapterFileMode
        let enforceQueryOnly: Bool
        switch location.accessMode {
        case .readOnly:
            mode = .readOnly
            enforceQueryOnly = false
        case .readWrite:
            mode = effectiveReadOnly ? .readOnly : .readWrite
            enforceQueryOnly = false
        case .createIfMissing:
            mode = .readWriteCreate
            enforceQueryOnly = effectiveReadOnly
        }
        return SQLiteDatabaseAdapterFilePlan(
            path: canonicalPath,
            mode: mode,
            enforceQueryOnly: enforceQueryOnly,
            identity: identity)
    }

    private static func validateMemoryName(
        _ name: String?
    ) throws(DatabaseAdapterFailure) {
        guard let name else { return }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !name.isEmpty,
            name.utf8.count <= 128,
            name.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw invalidConnection
        }
    }

    private static func configuration(
        connection: DatabaseConnectionDefinition,
        readOnly: Bool,
        enforceQueryOnly: Bool
    ) -> Configuration {
        var configuration = Configuration()
        configuration.label = "EdithDatabase.SQLite"
        configuration.readonly = readOnly
        configuration.busyMode = .timeout(
            TimeInterval(connection.limits.operationTimeout.milliseconds) / 1_000)
        if enforceQueryOnly {
            configuration.prepareDatabase { database in
                try database.execute(sql: "PRAGMA query_only = ON")
            }
        }
        return configuration
    }

    private static func fileURI(
        path: String,
        mode: SQLiteDatabaseAdapterFileMode
    ) throws(DatabaseAdapterFailure) -> String {
        guard
            var components = URLComponents(
                url: URL(fileURLWithPath: path),
                resolvingAgainstBaseURL: false)
        else {
            throw invalidConnection
        }
        components.queryItems = [URLQueryItem(name: "mode", value: mode.rawValue)]
        guard let url = components.url else {
            throw invalidConnection
        }
        return url.absoluteString
    }

    private static func isSymbolicLink(at path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private static func regularFileAttributes(
        at path: String
    ) -> [FileAttributeKey: Any]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else {
            return nil
        }
        return attributes
    }

    private static func fileIdentity(
        _ attributes: [FileAttributeKey: Any]
    ) -> SQLiteDatabaseAdapterFileIdentity? {
        guard let systemNumber = attributes[.systemNumber] as? NSNumber,
            let fileNumber = attributes[.systemFileNumber] as? NSNumber
        else {
            return nil
        }
        return SQLiteDatabaseAdapterFileIdentity(
            systemNumber: systemNumber.uint64Value,
            fileNumber: fileNumber.uint64Value)
    }
}
