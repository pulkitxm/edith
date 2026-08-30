import Foundation
import GRDB
import GRDBSQLite

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
    private var activeOperation: SQLiteDatabaseAdapterActiveOperation?

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
        guard activeOperation == nil else {
            throw SQLiteDatabaseAdapterSupport.operationBusy
        }
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
        let startedAt = Date()
        let connectionID = connection.id
        let output = try await performRead(
            context: context,
            failure: SQLiteDatabaseAdapterSupport.readFailed
        ) { database in
            try SQLiteDatabaseAdapterSupport.readPage(
                request,
                connectionID: connectionID,
                database: database,
                deadline: context.deadline)
        }
        let page = try SQLiteDatabaseAdapterSupport.page(
            output,
            request: request,
            kind: .browse,
            startedAt: startedAt,
            allowsContinuation: true)
        try page.validate(for: request)
        return page
    }

    func query(
        _ request: DatabaseAdapterQueryRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let startedAt = Date()
        let connectionID = connection.id
        let output = try await performRead(
            context: context,
            failure: SQLiteDatabaseAdapterSupport.queryFailed
        ) { database in
            try SQLiteDatabaseAdapterSupport.query(
                request,
                connectionID: connectionID,
                database: database,
                deadline: context.deadline)
        }
        let page = try SQLiteDatabaseAdapterSupport.page(
            output,
            request: request.source,
            kind: .query,
            startedAt: startedAt,
            allowsContinuation: false)
        try page.validate(for: request.source)
        return page
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

    func cancel(_ operationID: DatabaseOperationID) async -> DatabaseAdapterCancellationResult {
        guard let activeOperation, activeOperation.operationID == operationID else {
            return DatabaseAdapterCancellationResult(
                support: .cooperative,
                disposition: .alreadyFinished)
        }
        await activeOperation.cancellation.cancel(.userRequested)
        if self.activeOperation?.operationID == operationID {
            databaseQueue?.interrupt()
        }
        return DatabaseAdapterCancellationResult(
            support: .cooperative,
            disposition: .accepted)
    }

    func disconnect() async {
        guard state == .connected || state == .failed else { return }
        state = .disconnecting
        if let activeOperation {
            await activeOperation.cancellation.cancel(.sessionDisconnected)
        }
        databaseQueue?.interrupt()
        try? databaseQueue?.close()
        databaseQueue = nil
        activeOperation = nil
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
        guard activeOperation == nil else { return false }
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

    private func performRead<Output: Sendable>(
        context: DatabaseAdapterOperationContext,
        failure: DatabaseAdapterFailure,
        body: @escaping @Sendable (Database) throws -> Output
    ) async throws(DatabaseAdapterFailure) -> Output {
        try await SQLiteDatabaseAdapterSupport.check(context)
        let databaseQueue = try connectedDatabase()
        guard activeOperation == nil else {
            throw SQLiteDatabaseAdapterSupport.operationBusy
        }
        activeOperation = SQLiteDatabaseAdapterActiveOperation(
            operationID: context.operationID,
            cancellation: context.cancellation)

        let cancellationTask = Task { [weak self] in
            for await _ in await context.cancellation.events() {
                guard !Task.isCancelled else { return }
                await self?.interrupt(operationID: context.operationID)
                return
            }
        }
        let deadlineTask = context.deadline.map { deadline in
            Task { [weak self] in
                let delay = max(0, deadline.timeIntervalSinceNow)
                let nanoseconds = UInt64(
                    min(delay * 1_000_000_000, Double(UInt64.max)))
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await context.cancellation.cancel(.deadlineExceeded)
                await self?.interrupt(operationID: context.operationID)
            }
        }
        defer {
            cancellationTask.cancel()
            deadlineTask?.cancel()
            if activeOperation?.operationID == context.operationID {
                activeOperation = nil
            }
        }

        do {
            let output = try await withTaskCancellationHandler {
                try await databaseQueue.unsafeRead { database in
                    try SQLiteDatabaseAdapterSupport.queryOnlyRead(
                        database,
                        body: body)
                }
            } onCancel: {
                databaseQueue.interrupt()
            }
            try await SQLiteDatabaseAdapterSupport.check(context)
            return output
        } catch let adapterFailure as DatabaseAdapterFailure {
            throw adapterFailure
        } catch {
            let cancellationReason = await context.cancellation.reason()
            switch cancellationReason {
            case .deadlineExceeded:
                throw SQLiteDatabaseAdapterSupport.deadlineExceeded
            case .userRequested, .sessionDisconnected:
                throw .cancelled
            case nil:
                break
            }
            if Task.isCancelled {
                throw .cancelled
            }
            if error is SQLiteDatabaseAdapterExecutionInterruption
                || context.deadline.map({ $0 <= Date() }) == true
            {
                throw SQLiteDatabaseAdapterSupport.deadlineExceeded
            }
            if let databaseError = error as? GRDB.DatabaseError,
                databaseError.resultCode == .SQLITE_TOOBIG
            {
                throw SQLiteDatabaseAdapterSupport.resultTooLarge
            }
            throw failure
        }
    }

    private func interrupt(operationID: DatabaseOperationID) {
        guard activeOperation?.operationID == operationID else { return }
        databaseQueue?.interrupt()
    }

    private func failAndClose() {
        databaseQueue?.interrupt()
        try? databaseQueue?.close()
        databaseQueue = nil
        state = .failed
    }
}

private struct SQLiteDatabaseAdapterActiveOperation: Sendable {
    let operationID: DatabaseOperationID
    let cancellation: DatabaseAdapterCancellationSignal
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

private enum SQLiteDatabaseAdapterExecutionInterruption: Error {
    case deadlineExceeded
}

private enum SQLiteDatabaseAdapterContinuationKind: String, Codable, Sendable {
    case browse
    case query
}

private struct SQLiteDatabaseAdapterContinuationPayload: Codable, Sendable {
    let version: Int
    let kind: SQLiteDatabaseAdapterContinuationKind
    let offset: UInt64
}

private struct SQLiteDatabaseAdapterReadOutput: Sendable {
    let records: [DatabaseRecord]
    let fields: [DatabaseFieldDescriptor]
    let offset: UInt64
    let hasMore: Bool
}

private struct SQLiteDatabaseAdapterColumn: Sendable {
    let name: String
    let typeName: String
    let isNullable: Bool
    let primaryKeyIndex: Int
}

private struct SQLiteDatabaseAdapterSelectedColumn: Sendable {
    let source: SQLiteDatabaseAdapterColumn
    let outputName: String
}

private struct SQLiteDatabaseAdapterIdentityColumn: Sendable {
    let name: String
    let expression: String
}

private struct SQLiteDatabaseAdapterIdentityPlan: Sendable {
    let columns: [SQLiteDatabaseAdapterIdentityColumn]
    let kind: DatabaseRecordIdentityKind
}

private struct SQLiteDatabaseAdapterSQLFragment: Sendable {
    let sql: String
    let arguments: [GRDB.DatabaseValue]
}

private enum SQLiteDatabaseAdapterSQLLexeme {
    case word(String)
    case quotedIdentifier(String)
    case string(String)
    case symbol(UInt8)
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

    static let operationBusy = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .conflict,
            message: "The SQLite session is already executing an operation.",
            productCode: "sqlite.operation.busy",
            retry: DatabaseRetryGuidance(action: .retry)))

    static let readFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .server,
            message: "The SQLite table page could not be read.",
            productCode: "sqlite.read.failed",
            retry: DatabaseRetryGuidance(action: .none)))

    static let queryFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .server,
            message: "The SQLite query could not be executed.",
            productCode: "sqlite.query.failed",
            retry: DatabaseRetryGuidance(action: .none)))

    private static let invalidRead = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The SQLite table page request is invalid.",
            productCode: "sqlite.read.invalid",
            retry: DatabaseRetryGuidance(action: .none)))

    private static let invalidQuery = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The SQLite query request is invalid.",
            productCode: "sqlite.query.invalid",
            retry: DatabaseRetryGuidance(action: .none)))

    private static let unsupportedFilter = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .unsupported,
            message: "The requested SQLite filter operation is unavailable.",
            productCode: "sqlite.filter.unsupported",
            retry: DatabaseRetryGuidance(action: .none)))

    static let resultTooLarge = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .resourceLimit,
            message: "The SQLite result exceeds the bounded page limit.",
            productCode: "sqlite.result.too_large",
            retry: DatabaseRetryGuidance(action: .none)))

    private static let invalidContinuation = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The SQLite continuation is invalid.",
            productCode: "sqlite.continuation.invalid",
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

    static let deadlineExceeded = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .timeout,
            message: "The database operation deadline was exceeded.",
            productCode: "sqlite.deadline_exceeded",
            retry: DatabaseRetryGuidance(action: .none)))

    static func check(
        _ context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) {
        switch await context.cancellation.reason() {
        case .deadlineExceeded:
            throw deadlineExceeded
        case .userRequested, .sessionDisconnected:
            throw .cancelled
        case nil:
            break
        }
        if Task.isCancelled {
            throw .cancelled
        }
        guard let deadline = context.deadline else { return }
        guard deadline.timeIntervalSinceReferenceDate.isFinite, deadline > Date() else {
            throw deadlineExceeded
        }
    }

    static func queryOnlyRead<Output>(
        _ database: Database,
        body: (Database) throws -> Output
    ) throws -> Output {
        let queryOnly = try Int.fetchOne(database, sql: "PRAGMA query_only") == 1
        if !queryOnly {
            try database.execute(sql: "PRAGMA query_only = ON")
        }
        defer {
            if !queryOnly {
                try? database.execute(sql: "PRAGMA query_only = OFF")
            }
        }
        return try body(database)
    }

    static func readPage(
        _ request: DatabaseAdapterPageRequest,
        connectionID: DatabaseConnectionID,
        database: Database,
        deadline: Date?
    ) throws -> SQLiteDatabaseAdapterReadOutput {
        try validateConsistency(request.consistency, failure: invalidRead)
        let target = try browseTarget(request.target, connectionID: connectionID)
        let offset = try continuationOffset(request.continuation, kind: .browse)
        guard try database.tableExists(target.table, in: target.schema) else {
            throw invalidRead
        }
        let discoveredColumns = try tableColumns(
            database: database,
            schema: target.schema,
            table: target.table)
        let tableAlias = "_edith_table"
        let identity = try identityPlan(
            database: database,
            schema: target.schema,
            table: target.table,
            available: discoveredColumns,
            sourceAlias: tableAlias)
        let nonNullIdentityNames = Set(
            identity.kind == .primaryKey
                ? identity.columns.map { fold($0.name) }
                : [])
        let columns = discoveredColumns.map { column in
            SQLiteDatabaseAdapterColumn(
                name: column.name,
                typeName: column.typeName,
                isNullable: column.isNullable
                    && !nonNullIdentityNames.contains(fold(column.name)),
                primaryKeyIndex: column.primaryKeyIndex)
        }
        let selected = try selectedColumns(
            columns,
            projection: request.projection,
            failure: invalidRead)
        let filter = try filterSQL(
            request.filter,
            available: columns,
            sourceAlias: tableAlias,
            failure: invalidRead)
        let order = try browseOrderSQL(
            request.sorts,
            available: columns,
            sourceAlias: tableAlias,
            identityColumns: identity.columns,
            failure: invalidRead)
        var selections = selected.map { selectedColumn in
            let source = qualified(tableAlias, selectedColumn.source.name)
            return "\(source) AS \(quote(selectedColumn.outputName))"
        }
        selections.append(
            contentsOf: identity.columns.enumerated().map { index, identityColumn in
                "\(identityColumn.expression) AS \(quote("_edith_identity_\(index)"))"
            })
        var sql = "SELECT \(selections.joined(separator: ", ")) FROM "
        sql += "\(quote(target.schema)).\(quote(target.table)) AS \(quote(tableAlias))"
        if !filter.sql.isEmpty {
            sql += " WHERE \(filter.sql)"
        }
        sql += " ORDER BY \(order.joined(separator: ", ")) LIMIT ? OFFSET ?"
        var arguments = StatementArguments(filter.arguments)
        _ = arguments.append(
            contentsOf: StatementArguments([
                Int64(request.pageSize.value + 1),
                Int64(offset),
            ]))
        let statement = try database.makeStatement(sql: sql)
        return try fetchPage(
            statement: statement,
            arguments: arguments,
            selected: selected,
            identityColumns: identity.columns,
            identityKind: identity.kind,
            pageSize: request.pageSize.value,
            offset: offset,
            deadline: deadline)
    }

    static func query(
        _ request: DatabaseAdapterQueryRequest,
        connectionID: DatabaseConnectionID,
        database: Database,
        deadline: Date?
    ) throws -> SQLiteDatabaseAdapterReadOutput {
        try validateConsistency(request.source.consistency, failure: invalidQuery)
        try validateQueryTarget(request.source.target, connectionID: connectionID)
        guard request.language == .sql,
            request.body == nil,
            !request.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            request.command.utf8.count <= 262_144,
            request.parameters.count <= 512,
            allowedReadCommand(request.command)
        else {
            throw invalidQuery
        }
        guard request.source.continuation == nil else {
            throw invalidQuery
        }
        let offset = try continuationOffset(request.source.continuation, kind: .query)
        let sourceStatement: Statement
        do {
            sourceStatement = try database.makeStatement(sql: request.command)
        } catch {
            throw invalidQuery
        }
        guard sourceStatement.isReadonly,
            !sourceStatement.columnNames.isEmpty,
            sourceStatement.columnNames.count <= DatabaseAdapterBounds.maximumPageFields
        else {
            throw invalidQuery
        }
        var seenColumnNames = Set<String>()
        let columns = try sourceStatement.columnNames.map { name in
            try validateResultIdentifier(name, failure: invalidQuery)
            guard seenColumnNames.insert(fold(name)).inserted else {
                throw invalidQuery
            }
            return SQLiteDatabaseAdapterColumn(
                name: name,
                typeName: "dynamic",
                isNullable: true,
                primaryKeyIndex: 0)
        }
        let selected = try selectedColumns(
            columns,
            projection: request.source.projection,
            failure: invalidQuery)
        let sourceAlias = "_edith_query"
        let filter = try filterSQL(
            request.source.filter,
            available: columns,
            sourceAlias: sourceAlias,
            failure: invalidQuery)
        let order = try orderSQL(
            request.source.sorts,
            available: columns,
            sourceAlias: sourceAlias,
            failure: invalidQuery)
        let selections = selected.map { selectedColumn in
            let source = qualified(sourceAlias, selectedColumn.source.name)
            return "\(source) AS \(quote(selectedColumn.outputName))"
        }
        var sql = "SELECT \(selections.joined(separator: ", ")) FROM "
        sql += "(\(sourceStatement.sql)\n) AS \(quote(sourceAlias))"
        if !filter.sql.isEmpty {
            sql += " WHERE \(filter.sql)"
        }
        if !order.isEmpty {
            sql += " ORDER BY \(order.joined(separator: ", "))"
        }
        sql += " LIMIT ? OFFSET ?"
        var arguments = try queryArguments(request.parameters)
        _ = arguments.append(contentsOf: StatementArguments(filter.arguments))
        _ = arguments.append(
            contentsOf: StatementArguments([
                Int64(request.source.pageSize.value + 1),
                Int64(offset),
            ]))
        let statement: Statement
        do {
            statement = try database.makeStatement(sql: sql)
            guard statement.isReadonly else {
                throw invalidQuery
            }
            try statement.setArguments(arguments)
        } catch let failure as DatabaseAdapterFailure {
            throw failure
        } catch {
            throw invalidQuery
        }
        return try fetchPage(
            statement: statement,
            arguments: arguments,
            selected: selected,
            identityColumns: [],
            identityKind: nil,
            pageSize: request.source.pageSize.value,
            offset: offset,
            deadline: deadline)
    }

    static func page(
        _ output: SQLiteDatabaseAdapterReadOutput,
        request: DatabaseAdapterPageRequest,
        kind: SQLiteDatabaseAdapterContinuationKind,
        startedAt: Date,
        allowsContinuation: Bool
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let endingOffset = output.offset + UInt64(output.records.count)
        let nextContinuation: DatabaseAdapterContinuation?
        if output.hasMore, allowsContinuation {
            guard endingOffset <= 1_000_000 else {
                throw resultTooLarge
            }
            let payload: Data
            do {
                payload = try JSONEncoder().encode(
                    SQLiteDatabaseAdapterContinuationPayload(
                        version: 1,
                        kind: kind,
                        offset: endingOffset))
            } catch {
                throw invalidContinuation
            }
            nextContinuation = try DatabaseAdapterContinuation(
                mode: .offset,
                payload: payload)
        } else {
            nextContinuation = nil
        }
        let completeness: DatabaseResultCompleteness
        if output.hasMore, !allowsContinuation {
            completeness = DatabaseResultCompleteness(
                state: .truncated,
                reason: "SQLite query continuation is unavailable.")
        } else if output.hasMore {
            completeness = DatabaseResultCompleteness(
                state: .partial,
                reason: "More rows are available.")
        } else {
            completeness = DatabaseResultCompleteness(state: .complete)
        }
        let duration = max(0, Date().timeIntervalSince(startedAt))
        let durationMilliseconds = UInt64(
            min(duration * 1_000, Double(UInt64.max)))
        let metadata = DatabasePageMetadata(
            completeness: completeness,
            count: DatabaseCountMetadata(
                value: endingOffset,
                accuracy: output.hasMore ? .lowerBound : .exact),
            timing: DatabaseQueryTiming(durationMilliseconds: durationMilliseconds))
        return try DatabaseAdapterPage(
            records: output.records,
            fields: output.fields,
            nextContinuation: nextContinuation,
            metadata: metadata)
    }

    private static func browseTarget(
        _ target: DatabaseTargetIdentifier,
        connectionID: DatabaseConnectionID
    ) throws -> (schema: String, table: String) {
        guard target.connectionID == connectionID,
            target.record == nil,
            let object = target.object,
            object.kind == .table,
            object.nativeIdentifier == nil,
            object.path.count == 1 || object.path.count == 2
        else {
            throw invalidRead
        }
        let schema: String
        let table: String
        if object.path.count == 1 {
            schema = "main"
            table = object.path[0]
        } else {
            schema = object.path[0].lowercased()
            table = object.path[1]
        }
        guard schema == "main" || schema == "temp" else {
            throw invalidRead
        }
        try validateResultIdentifier(table, failure: invalidRead)
        return (schema, table)
    }

    private static func validateQueryTarget(
        _ target: DatabaseTargetIdentifier,
        connectionID: DatabaseConnectionID
    ) throws {
        guard target.connectionID == connectionID, target.record == nil else {
            throw invalidQuery
        }
        guard let object = target.object else { return }
        guard object.nativeIdentifier == nil,
            !object.path.isEmpty,
            object.path.count <= 4
        else {
            throw invalidQuery
        }
        for segment in object.path {
            try validateResultIdentifier(segment, failure: invalidQuery)
        }
    }

    private static func continuationOffset(
        _ continuation: DatabaseAdapterContinuation?,
        kind: SQLiteDatabaseAdapterContinuationKind
    ) throws -> UInt64 {
        guard let continuation else { return 0 }
        guard continuation.mode == .offset,
            continuation.expiresAt.map({
                $0.timeIntervalSinceReferenceDate.isFinite && $0 > Date()
            }) != false
        else {
            throw invalidContinuation
        }
        let payload: SQLiteDatabaseAdapterContinuationPayload
        do {
            payload = try JSONDecoder().decode(
                SQLiteDatabaseAdapterContinuationPayload.self,
                from: continuation.payload)
        } catch {
            throw invalidContinuation
        }
        guard payload.version == 1,
            payload.kind == kind,
            payload.offset <= 1_000_000,
            payload.offset <= UInt64(Int64.max)
        else {
            throw invalidContinuation
        }
        return payload.offset
    }

    private static func selectedColumns(
        _ available: [SQLiteDatabaseAdapterColumn],
        projection: DatabaseProjection?,
        failure: DatabaseAdapterFailure
    ) throws -> [SQLiteDatabaseAdapterSelectedColumn] {
        guard let projection else {
            guard available.count <= DatabaseAdapterBounds.maximumPageFields else {
                throw failure
            }
            return available.map {
                SQLiteDatabaseAdapterSelectedColumn(source: $0, outputName: $0.name)
            }
        }
        var selected: [SQLiteDatabaseAdapterSelectedColumn]
        switch projection.mode {
        case .include:
            guard !projection.fields.isEmpty else {
                throw failure
            }
            var seenSources = Set<String>()
            selected = try projection.fields.map { projectedField in
                let source = try resolve(
                    projectedField.path,
                    available: available,
                    failure: failure)
                guard seenSources.insert(fold(source.name)).inserted else {
                    throw failure
                }
                let outputName = projectedField.alias ?? source.name
                try validateResultIdentifier(outputName, failure: failure)
                return SQLiteDatabaseAdapterSelectedColumn(
                    source: source,
                    outputName: outputName)
            }
        case .exclude:
            var excluded = Set<String>()
            for projectedField in projection.fields {
                guard projectedField.alias == nil else {
                    throw failure
                }
                let source = try resolve(
                    projectedField.path,
                    available: available,
                    failure: failure)
                guard excluded.insert(fold(source.name)).inserted else {
                    throw failure
                }
            }
            selected = available.compactMap { column in
                excluded.contains(fold(column.name))
                    ? nil
                    : SQLiteDatabaseAdapterSelectedColumn(
                        source: column,
                        outputName: column.name)
            }
        }
        guard !selected.isEmpty,
            selected.count <= DatabaseAdapterBounds.maximumPageFields
        else {
            throw failure
        }
        var seenOutputs = Set<String>()
        guard selected.allSatisfy({ seenOutputs.insert(fold($0.outputName)).inserted }) else {
            throw failure
        }
        return selected
    }

    private static func tableColumns(
        database: Database,
        schema: String,
        table: String
    ) throws -> [SQLiteDatabaseAdapterColumn] {
        let cursor = try Row.fetchCursor(
            database,
            sql: """
                SELECT name, type, "notnull", pk
                FROM pragma_table_xinfo(?, ?)
                WHERE hidden <> 1
                LIMIT 513
                """,
            arguments: [table, schema])
        var columns: [SQLiteDatabaseAdapterColumn] = []
        var seen = Set<String>()
        while let row = try cursor.next() {
            let name: String = row["name"]
            let type: String = row["type"]
            let isNotNull: Int = row["notnull"]
            let primaryKeyIndex: Int = row["pk"]
            try validateResultIdentifier(name, failure: invalidRead)
            guard type.utf8.count <= 1_024,
                !type.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw invalidRead
            }
            guard seen.insert(fold(name)).inserted else {
                throw invalidRead
            }
            columns.append(
                SQLiteDatabaseAdapterColumn(
                    name: name,
                    typeName: type.isEmpty ? "dynamic" : type,
                    isNullable: isNotNull == 0,
                    primaryKeyIndex: primaryKeyIndex))
        }
        guard !columns.isEmpty,
            columns.count <= DatabaseAdapterBounds.maximumPageFields
        else {
            throw invalidRead
        }
        return columns
    }

    private static func identityPlan(
        database: Database,
        schema: String,
        table: String,
        available: [SQLiteDatabaseAdapterColumn],
        sourceAlias: String
    ) throws -> SQLiteDatabaseAdapterIdentityPlan {
        let primaryKey =
            available
            .filter { $0.primaryKeyIndex > 0 }
            .sorted { $0.primaryKeyIndex < $1.primaryKeyIndex }
        if primaryKey.count == 1,
            fold(primaryKey[0].typeName) == "integer"
        {
            let regularPrimaryKeyIndex: Int?
            do {
                regularPrimaryKeyIndex = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT 1
                        FROM pragma_index_list(?, ?)
                        WHERE origin = 'pk'
                        LIMIT 1
                        """,
                    arguments: [table, schema])
            } catch {
                throw invalidRead
            }
            if regularPrimaryKeyIndex == nil {
                return SQLiteDatabaseAdapterIdentityPlan(
                    columns: [
                        SQLiteDatabaseAdapterIdentityColumn(
                            name: primaryKey[0].name,
                            expression: qualified(sourceAlias, primaryKey[0].name))
                    ],
                    kind: .primaryKey)
            }
        }
        if !primaryKey.isEmpty, primaryKey.allSatisfy({ !$0.isNullable }) {
            return SQLiteDatabaseAdapterIdentityPlan(
                columns: primaryKey.map { column in
                    SQLiteDatabaseAdapterIdentityColumn(
                        name: column.name,
                        expression: qualified(sourceAlias, column.name))
                },
                kind: .primaryKey)
        }
        let existing = Set(available.map { fold($0.name) })
        guard
            let alias = ["rowid", "_rowid_", "oid"].first(where: {
                !existing.contains(fold($0))
            })
        else {
            throw invalidRead
        }
        let probeAlias = "_edith_probe"
        let probeSQL =
            "SELECT \(qualified(probeAlias, alias)) FROM "
            + "\(quote(schema)).\(quote(table)) AS \(quote(probeAlias)) LIMIT 0"
        do {
            _ = try database.makeStatement(sql: probeSQL)
        } catch {
            throw invalidRead
        }
        return SQLiteDatabaseAdapterIdentityPlan(
            columns: [
                SQLiteDatabaseAdapterIdentityColumn(
                    name: alias,
                    expression: qualified(sourceAlias, alias))
            ],
            kind: .rowID)
    }

    private static func browseOrderSQL(
        _ sorts: [DatabaseSort],
        available: [SQLiteDatabaseAdapterColumn],
        sourceAlias: String,
        identityColumns: [SQLiteDatabaseAdapterIdentityColumn],
        failure: DatabaseAdapterFailure
    ) throws -> [String] {
        var terms = try orderSQL(
            sorts,
            available: available,
            sourceAlias: sourceAlias,
            failure: failure)
        let sortedNames = try Set(
            sorts.map {
                fold(try resolve($0.field, available: available, failure: failure).name)
            })
        for identityColumn in identityColumns where !sortedNames.contains(fold(identityColumn.name))
        {
            terms.append("\(identityColumn.expression) ASC")
        }
        guard !terms.isEmpty else {
            throw failure
        }
        return terms
    }

    private static func orderSQL(
        _ sorts: [DatabaseSort],
        available: [SQLiteDatabaseAdapterColumn],
        sourceAlias: String,
        failure: DatabaseAdapterFailure
    ) throws -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for sort in sorts {
            let column = try resolve(sort.field, available: available, failure: failure)
            guard seen.insert(fold(column.name)).inserted else {
                throw failure
            }
            let expression = qualified(sourceAlias, column.name)
            switch sort.nullPlacement {
            case .productDefault:
                break
            case .first:
                terms.append("(\(expression) IS NOT NULL) ASC")
            case .last:
                terms.append("(\(expression) IS NULL) ASC")
            }
            let direction = sort.direction == .ascending ? "ASC" : "DESC"
            terms.append("\(expression) \(direction)")
        }
        return terms
    }

    private static func filterSQL(
        _ filter: DatabaseFilter?,
        available: [SQLiteDatabaseAdapterColumn],
        sourceAlias: String,
        failure: DatabaseAdapterFailure
    ) throws -> SQLiteDatabaseAdapterSQLFragment {
        guard let filter else {
            return SQLiteDatabaseAdapterSQLFragment(sql: "", arguments: [])
        }
        var nodeCount = 0
        var valueCount = 0
        return try filterSQL(
            filter,
            available: available,
            sourceAlias: sourceAlias,
            failure: failure,
            depth: 0,
            nodeCount: &nodeCount,
            valueCount: &valueCount)
    }

    private static func filterSQL(
        _ filter: DatabaseFilter,
        available: [SQLiteDatabaseAdapterColumn],
        sourceAlias: String,
        failure: DatabaseAdapterFailure,
        depth: Int,
        nodeCount: inout Int,
        valueCount: inout Int
    ) throws -> SQLiteDatabaseAdapterSQLFragment {
        nodeCount += 1
        guard depth <= 16, nodeCount <= 256 else {
            throw failure
        }
        switch filter {
        case let .predicate(predicate):
            valueCount += predicate.values.count
            guard valueCount <= 512 else {
                throw failure
            }
            return try predicateSQL(
                predicate,
                available: available,
                sourceAlias: sourceAlias,
                failure: failure)
        case let .all(children):
            return try compoundFilterSQL(
                children,
                separator: " AND ",
                available: available,
                sourceAlias: sourceAlias,
                failure: failure,
                depth: depth,
                nodeCount: &nodeCount,
                valueCount: &valueCount)
        case let .any(children):
            return try compoundFilterSQL(
                children,
                separator: " OR ",
                available: available,
                sourceAlias: sourceAlias,
                failure: failure,
                depth: depth,
                nodeCount: &nodeCount,
                valueCount: &valueCount)
        case let .not(child):
            let fragment = try filterSQL(
                child,
                available: available,
                sourceAlias: sourceAlias,
                failure: failure,
                depth: depth + 1,
                nodeCount: &nodeCount,
                valueCount: &valueCount)
            return SQLiteDatabaseAdapterSQLFragment(
                sql: "NOT (\(fragment.sql))",
                arguments: fragment.arguments)
        }
    }

    private static func compoundFilterSQL(
        _ children: [DatabaseFilter],
        separator: String,
        available: [SQLiteDatabaseAdapterColumn],
        sourceAlias: String,
        failure: DatabaseAdapterFailure,
        depth: Int,
        nodeCount: inout Int,
        valueCount: inout Int
    ) throws -> SQLiteDatabaseAdapterSQLFragment {
        guard !children.isEmpty, children.count <= 256 else {
            throw failure
        }
        var sql: [String] = []
        var arguments: [GRDB.DatabaseValue] = []
        for child in children {
            let fragment = try filterSQL(
                child,
                available: available,
                sourceAlias: sourceAlias,
                failure: failure,
                depth: depth + 1,
                nodeCount: &nodeCount,
                valueCount: &valueCount)
            sql.append("(\(fragment.sql))")
            arguments.append(contentsOf: fragment.arguments)
        }
        return SQLiteDatabaseAdapterSQLFragment(
            sql: sql.joined(separator: separator),
            arguments: arguments)
    }

    private static func predicateSQL(
        _ predicate: DatabaseFilterPredicate,
        available: [SQLiteDatabaseAdapterColumn],
        sourceAlias: String,
        failure: DatabaseAdapterFailure
    ) throws -> SQLiteDatabaseAdapterSQLFragment {
        let column = try resolve(predicate.field, available: available, failure: failure)
        let expression = qualified(sourceAlias, column.name)
        switch predicate.operation {
        case .equal, .notEqual:
            guard predicate.values.count == 1 else { throw failure }
            if predicate.values[0] == .null {
                let operation = predicate.operation == .equal ? "IS NULL" : "IS NOT NULL"
                return SQLiteDatabaseAdapterSQLFragment(
                    sql: "\(expression) \(operation)",
                    arguments: [])
            }
            let compared = try comparisonExpression(
                expression,
                value: predicate.values[0],
                sensitivity: predicate.caseSensitivity,
                failure: failure)
            let operation = predicate.operation == .equal ? "=" : "<>"
            return SQLiteDatabaseAdapterSQLFragment(
                sql: "\(compared) \(operation) ?",
                arguments: [try bindValue(predicate.values[0], failure: failure)])
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            guard predicate.values.count == 1, predicate.values[0] != .null else {
                throw failure
            }
            let compared = try comparisonExpression(
                expression,
                value: predicate.values[0],
                sensitivity: predicate.caseSensitivity,
                failure: failure)
            let operation: String
            switch predicate.operation {
            case .greaterThan:
                operation = ">"
            case .greaterThanOrEqual:
                operation = ">="
            case .lessThan:
                operation = "<"
            case .lessThanOrEqual:
                operation = "<="
            default:
                throw failure
            }
            return SQLiteDatabaseAdapterSQLFragment(
                sql: "\(compared) \(operation) ?",
                arguments: [try bindValue(predicate.values[0], failure: failure)])
        case .contains, .startsWith, .endsWith:
            guard predicate.values.count == 1,
                case let .string(text) = predicate.values[0]
            else {
                throw failure
            }
            return try textPredicateSQL(
                expression: expression,
                operation: predicate.operation,
                text: text,
                sensitivity: predicate.caseSensitivity,
                failure: failure)
        case .in, .notIn:
            guard !predicate.values.isEmpty, predicate.values.count <= 512 else {
                throw failure
            }
            return try membershipPredicateSQL(
                expression: expression,
                predicate: predicate,
                failure: failure)
        case .between:
            guard predicate.values.count == 2,
                predicate.values.allSatisfy({ $0 != .null })
            else {
                throw failure
            }
            let compared = try comparisonExpression(
                expression,
                value: predicate.values[0],
                sensitivity: predicate.caseSensitivity,
                failure: failure)
            if predicate.caseSensitivity != .productDefault {
                guard case .string = predicate.values[1] else { throw failure }
            }
            return SQLiteDatabaseAdapterSQLFragment(
                sql: "\(compared) BETWEEN ? AND ?",
                arguments: try predicate.values.map {
                    try bindValue($0, failure: failure)
                })
        case .isNull, .isNotNull:
            guard predicate.values.isEmpty,
                predicate.caseSensitivity == .productDefault
            else {
                throw failure
            }
            let operation = predicate.operation == .isNull ? "IS NULL" : "IS NOT NULL"
            return SQLiteDatabaseAdapterSQLFragment(
                sql: "\(expression) \(operation)",
                arguments: [])
        case .isMissing, .isNotMissing, .regularExpression, .fullText:
            throw unsupportedFilter
        }
    }

    private static func comparisonExpression(
        _ expression: String,
        value: DatabaseValue,
        sensitivity: DatabaseFilterCaseSensitivity,
        failure: DatabaseAdapterFailure
    ) throws -> String {
        switch sensitivity {
        case .productDefault:
            return expression
        case .sensitive:
            guard case .string = value else { throw failure }
            return "\(expression) COLLATE BINARY"
        case .insensitive:
            guard case .string = value else { throw failure }
            return "\(expression) COLLATE NOCASE"
        }
    }

    private static func textPredicateSQL(
        expression: String,
        operation: DatabaseFilterOperator,
        text: String,
        sensitivity: DatabaseFilterCaseSensitivity,
        failure: DatabaseAdapterFailure
    ) throws -> SQLiteDatabaseAdapterSQLFragment {
        guard text.utf8.count <= 4_194_304 else {
            throw resultTooLarge
        }
        if text.isEmpty {
            return SQLiteDatabaseAdapterSQLFragment(
                sql: "\(expression) IS NOT NULL",
                arguments: [])
        }
        if sensitivity == .sensitive {
            let value = text.databaseValue
            switch operation {
            case .contains:
                return SQLiteDatabaseAdapterSQLFragment(
                    sql: "INSTR(CAST(\(expression) AS TEXT), ?) > 0",
                    arguments: [value])
            case .startsWith:
                return SQLiteDatabaseAdapterSQLFragment(
                    sql: "SUBSTR(CAST(\(expression) AS TEXT), 1, LENGTH(?)) = ? COLLATE BINARY",
                    arguments: [value, value])
            case .endsWith:
                return SQLiteDatabaseAdapterSQLFragment(
                    sql: "SUBSTR(CAST(\(expression) AS TEXT), -LENGTH(?)) = ? COLLATE BINARY",
                    arguments: [value, value])
            default:
                throw failure
            }
        }
        let escaped =
            text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern: String
        switch operation {
        case .contains:
            pattern = "%\(escaped)%"
        case .startsWith:
            pattern = "\(escaped)%"
        case .endsWith:
            pattern = "%\(escaped)"
        default:
            throw failure
        }
        let compared =
            sensitivity == .insensitive
            ? "LOWER(CAST(\(expression) AS TEXT))"
            : "CAST(\(expression) AS TEXT)"
        let placeholder = sensitivity == .insensitive ? "LOWER(?)" : "?"
        return SQLiteDatabaseAdapterSQLFragment(
            sql: "\(compared) LIKE \(placeholder) ESCAPE '\\'",
            arguments: [pattern.databaseValue])
    }

    private static func membershipPredicateSQL(
        expression: String,
        predicate: DatabaseFilterPredicate,
        failure: DatabaseAdapterFailure
    ) throws -> SQLiteDatabaseAdapterSQLFragment {
        let includesNull = predicate.values.contains(.null)
        let nonNull = predicate.values.filter { $0 != .null }
        if predicate.caseSensitivity != .productDefault {
            guard
                nonNull.allSatisfy({ value in
                    if case .string = value { return true }
                    return false
                })
            else {
                throw failure
            }
        }
        let compared: String
        switch predicate.caseSensitivity {
        case .productDefault:
            compared = expression
        case .sensitive:
            compared = "\(expression) COLLATE BINARY"
        case .insensitive:
            compared = "\(expression) COLLATE NOCASE"
        }
        let placeholders = Array(repeating: "?", count: nonNull.count).joined(separator: ", ")
        let membership: String?
        if nonNull.isEmpty {
            membership = nil
        } else {
            let operation = predicate.operation == .in ? "IN" : "NOT IN"
            membership = "\(compared) \(operation) (\(placeholders))"
        }
        let sql: String
        if predicate.operation == .in {
            switch (membership, includesNull) {
            case let (.some(membership), true):
                sql = "(\(membership) OR \(expression) IS NULL)"
            case let (.some(membership), false):
                sql = membership
            case (.none, true):
                sql = "\(expression) IS NULL"
            case (.none, false):
                throw failure
            }
        } else {
            switch (membership, includesNull) {
            case let (.some(membership), true):
                sql = "(\(membership) AND \(expression) IS NOT NULL)"
            case let (.some(membership), false):
                sql = membership
            case (.none, true):
                sql = "\(expression) IS NOT NULL"
            case (.none, false):
                throw failure
            }
        }
        return SQLiteDatabaseAdapterSQLFragment(
            sql: sql,
            arguments: try nonNull.map { try bindValue($0, failure: failure) })
    }

    private static func fetchPage(
        statement: Statement,
        arguments: StatementArguments,
        selected: [SQLiteDatabaseAdapterSelectedColumn],
        identityColumns: [SQLiteDatabaseAdapterIdentityColumn],
        identityKind: DatabaseRecordIdentityKind?,
        pageSize: Int,
        offset: UInt64,
        deadline: Date?
    ) throws -> SQLiteDatabaseAdapterReadOutput {
        try checkExecution(deadline: deadline)
        let cursor = try Row.fetchCursor(statement, arguments: arguments)
        let fields = selected.map { selectedColumn in
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath(selectedColumn.outputName),
                displayName: selectedColumn.outputName,
                typeName: selectedColumn.source.typeName,
                isNullable: selectedColumn.source.isNullable,
                isSortable: fold(selectedColumn.outputName) == fold(selectedColumn.source.name),
                isFilterable: fold(selectedColumn.outputName) == fold(selectedColumn.source.name))
        }
        var records: [DatabaseRecord] = []
        records.reserveCapacity(pageSize)
        let pageByteLimit = 12_582_912
        var bufferedBytes = selected.reduce(0) { byteCount, selectedColumn in
            byteCount + encodedStringBytes(selectedColumn.outputName)
                + encodedStringBytes(selectedColumn.source.typeName) + 96
        }
        guard bufferedBytes <= pageByteLimit else {
            throw resultTooLarge
        }
        let recordStructureBytes =
            selected.reduce(64) { byteCount, selectedColumn in
                byteCount + encodedStringBytes(selectedColumn.outputName) + 48
            }
            + identityColumns.reduce(0) { byteCount, identityColumn in
                byteCount + encodedStringBytes(identityColumn.name) + 48
            }
        var hasMore = false
        while let row = try cursor.next() {
            try checkExecution(deadline: deadline)
            if records.count == pageSize {
                hasMore = true
                break
            }
            var recordBytes = recordStructureBytes
            var recordFields: [DatabaseObjectField] = []
            recordFields.reserveCapacity(selected.count)
            var exceedsPage = recordBytes > pageByteLimit - bufferedBytes
            for (index, selectedColumn) in selected.enumerated() {
                let stored: GRDB.DatabaseValue = row[index]
                let storedBytes = try boundedStorageBytes(stored)
                if storedBytes > pageByteLimit - recordBytes {
                    exceedsPage = true
                    break
                }
                recordBytes += storedBytes
                recordFields.append(
                    DatabaseObjectField(
                        name: selectedColumn.outputName,
                        value: resultValue(stored)))
            }
            var identity: DatabaseRecordIdentity?
            if !exceedsPage, let identityKind {
                var components: [DatabaseIdentityComponent] = []
                components.reserveCapacity(identityColumns.count)
                for (index, column) in identityColumns.enumerated() {
                    let stored: GRDB.DatabaseValue = row[selected.count + index]
                    let storedBytes = try boundedStorageBytes(stored)
                    if storedBytes > pageByteLimit - recordBytes {
                        exceedsPage = true
                        break
                    }
                    recordBytes += storedBytes
                    components.append(
                        DatabaseIdentityComponent(
                            name: column.name,
                            value: resultValue(stored)))
                }
                if !exceedsPage {
                    identity = DatabaseRecordIdentity(
                        kind: identityKind,
                        components: components)
                }
            }
            if exceedsPage || recordBytes > pageByteLimit - bufferedBytes {
                guard !records.isEmpty else {
                    throw resultTooLarge
                }
                hasMore = true
                break
            }
            bufferedBytes += recordBytes
            records.append(DatabaseRecord(identity: identity, fields: recordFields))
        }
        return SQLiteDatabaseAdapterReadOutput(
            records: records,
            fields: fields,
            offset: offset,
            hasMore: hasMore)
    }

    private static func queryArguments(
        _ parameters: [DatabaseQueryParameter]
    ) throws -> StatementArguments {
        guard !parameters.isEmpty else { return StatementArguments() }
        let namedCount = parameters.count(where: { $0.name != nil })
        guard namedCount == 0 || namedCount == parameters.count else {
            throw invalidQuery
        }
        if namedCount == 0 {
            let values: [(any DatabaseValueConvertible)?] = try parameters.map {
                try bindValue($0.value, failure: invalidQuery).storage.value
            }
            return StatementArguments(values)
        }
        var seen = Set<String>()
        var values: [(String, (any DatabaseValueConvertible)?)] = []
        values.reserveCapacity(parameters.count)
        for parameter in parameters {
            guard let name = parameter.name,
                validParameterName(name),
                !name.lowercased().hasPrefix("_edith_"),
                seen.insert(name).inserted
            else {
                throw invalidQuery
            }
            values.append(
                (name, try bindValue(parameter.value, failure: invalidQuery).storage.value))
        }
        return StatementArguments(values)
    }

    private static func bindValue(
        _ value: DatabaseValue,
        failure: DatabaseAdapterFailure
    ) throws -> GRDB.DatabaseValue {
        switch value {
        case .missing, .array, .object, .productSpecific:
            throw failure
        case .null:
            return .null
        case let .boolean(value):
            return Int64(value ? 1 : 0).databaseValue
        case let .signedInteger(value):
            return value.databaseValue
        case let .unsignedInteger(value):
            guard value <= UInt64(Int64.max) else { throw failure }
            return Int64(value).databaseValue
        case let .decimal(value):
            guard validDecimal(value.rawValue), value.rawValue.utf8.count <= 128 else {
                throw failure
            }
            return value.rawValue.databaseValue
        case let .floatingPoint(value):
            guard value.isFinite else { throw failure }
            return value.databaseValue
        case let .string(value):
            guard value.utf8.count <= 4_194_304 else { throw resultTooLarge }
            return value.databaseValue
        case let .binary(value):
            guard case let .complete(data, _, _) = value,
                data.count <= 4_194_304
            else {
                throw failure
            }
            return data.databaseValue
        case let .date(value):
            guard validTextValue(value.text) else { throw failure }
            return value.text.databaseValue
        case let .time(value):
            guard validTextValue(value.text) else { throw failure }
            return value.text.databaseValue
        case let .timestamp(value):
            guard validTextValue(value.text) else { throw failure }
            return value.text.databaseValue
        case let .uuid(value):
            return value.uuidString.lowercased().databaseValue
        }
    }

    private static func resultValue(_ value: GRDB.DatabaseValue) -> DatabaseValue {
        switch value.storage {
        case .null:
            return .null
        case let .int64(value):
            return .signedInteger(value)
        case let .double(value):
            return .floatingPoint(value)
        case let .string(value):
            return .string(value)
        case let .blob(value):
            return .binary(.complete(data: value, mediaType: nil, digest: nil))
        }
    }

    private static func boundedStorageBytes(_ value: GRDB.DatabaseValue) throws -> Int {
        let byteCount: Int
        switch value.storage {
        case .null:
            byteCount = 1
        case .int64, .double:
            byteCount = 32
        case let .string(value):
            byteCount = encodedStringBytes(value)
        case let .blob(value):
            guard value.count <= 4_194_304 else {
                throw resultTooLarge
            }
            byteCount = ((value.count + 2) / 3) * 4 + 64
        }
        guard byteCount <= 4_194_304 else {
            throw resultTooLarge
        }
        return byteCount
    }

    private static func encodedStringBytes(_ value: String) -> Int {
        let (multiplied, overflow) = value.utf8.count.multipliedReportingOverflow(by: 6)
        let (total, additionOverflow) = multiplied.addingReportingOverflow(16)
        return overflow || additionOverflow ? Int.max : total
    }

    private static func resolve(
        _ path: DatabaseFieldPath,
        available: [SQLiteDatabaseAdapterColumn],
        failure: DatabaseAdapterFailure
    ) throws -> SQLiteDatabaseAdapterColumn {
        guard path.segments.count == 1 else { throw failure }
        let requested = path.segments[0]
        try validateResultIdentifier(requested, failure: failure)
        let matches = available.filter { fold($0.name) == fold(requested) }
        guard matches.count == 1, let match = matches.first else {
            throw failure
        }
        return match
    }

    private static func validateResultIdentifier(
        _ identifier: String,
        failure: DatabaseAdapterFailure
    ) throws {
        guard !identifier.isEmpty,
            identifier.utf8.count <= 1_024,
            !identifier.contains("\0"),
            !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw failure
        }
    }

    private static func validParameterName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 128 else { return false }
        let scalars = name.unicodeScalars
        guard let first = scalars.first,
            first == "_" || (65...90).contains(first.value) || (97...122).contains(first.value)
        else {
            return false
        }
        return scalars.dropFirst().allSatisfy { scalar in
            scalar == "_" || (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
        }
    }

    private static func allowedReadCommand(_ command: String) -> Bool {
        let lexemes = sqlLexemes(command)
        guard let first = lexemes.first,
            case let .word(root) = first,
            root == "SELECT" || root == "WITH" || root == "VALUES"
        else {
            return false
        }
        return !hasDangerousSQLSurface(lexemes)
    }

    private static func sqlLexemes(_ command: String) -> [SQLiteDatabaseAdapterSQLLexeme] {
        let bytes = Array(command.utf8)
        var lexemes: [SQLiteDatabaseAdapterSQLLexeme] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 39 {
                let delimiter = byte
                var quoted: [UInt8] = []
                index += 1
                while index < bytes.count {
                    if bytes[index] == delimiter {
                        if index + 1 < bytes.count, bytes[index + 1] == delimiter {
                            quoted.append(delimiter)
                            index += 2
                        } else {
                            index += 1
                            break
                        }
                    } else {
                        quoted.append(bytes[index])
                        index += 1
                    }
                }
                lexemes.append(.string(String(decoding: quoted, as: UTF8.self)))
                continue
            }
            if byte == 34 || byte == 96 || byte == 91 {
                let delimiter = byte == 91 ? UInt8(93) : byte
                var identifier: [UInt8] = []
                index += 1
                while index < bytes.count {
                    if bytes[index] == delimiter {
                        if delimiter != 93,
                            index + 1 < bytes.count,
                            bytes[index + 1] == delimiter
                        {
                            identifier.append(delimiter)
                            index += 2
                        } else {
                            index += 1
                            break
                        }
                    } else {
                        identifier.append(bytes[index])
                        index += 1
                    }
                }
                if let first = identifier.first,
                    isSQLIdentifierStart(first),
                    identifier.dropFirst().allSatisfy(isSQLIdentifierByte)
                {
                    lexemes.append(
                        .quotedIdentifier(
                            String(decoding: identifier, as: UTF8.self).uppercased()))
                }
                continue
            }
            if byte == 45, index + 1 < bytes.count, bytes[index + 1] == 45 {
                index += 2
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13 {
                    index += 1
                }
                continue
            }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 42 {
                index += 2
                while index + 1 < bytes.count,
                    !(bytes[index] == 42 && bytes[index + 1] == 47)
                {
                    index += 1
                }
                index = min(index + 2, bytes.count)
                continue
            }
            if byte == 36 || byte == 58 || byte == 64 {
                index += 1
                while index < bytes.count, isSQLIdentifierByte(bytes[index]) {
                    index += 1
                }
                continue
            }
            if isSQLIdentifierStart(byte) {
                let start = index
                index += 1
                while index < bytes.count, isSQLIdentifierByte(bytes[index]) {
                    index += 1
                }
                lexemes.append(
                    .word(String(decoding: bytes[start..<index], as: UTF8.self).uppercased()))
                continue
            }
            if byte == 40 || byte == 41 || byte == 44 || byte == 46 {
                lexemes.append(.symbol(byte))
            }
            index += 1
        }
        return lexemes
    }

    private static func hasDangerousSQLSurface(
        _ lexemes: [SQLiteDatabaseAdapterSQLLexeme]
    ) -> Bool {
        let clauseTerminators: Set<String> = [
            "EXCEPT", "GROUP", "HAVING", "INTERSECT", "LIMIT", "ORDER", "RETURNING",
            "UNION", "WHERE", "WINDOW",
        ]
        var depth = 0
        var fromDepths = Set<Int>()
        var expectsSource = false
        var sourceCanBeQualified = false
        for (index, lexeme) in lexemes.enumerated() {
            let isFunctionCall: Bool
            if index + 1 < lexemes.count,
                case .symbol(40) = lexemes[index + 1]
            {
                isFunctionCall = true
            } else {
                isFunctionCall = false
            }
            switch lexeme {
            case let .word(word):
                if dangerousSQLName(word), expectsSource || isFunctionCall {
                    return true
                }
                if expectsSource,
                    word == "SELECT" || word == "WITH" || word == "VALUES"
                {
                    fromDepths.remove(depth)
                    expectsSource = false
                    sourceCanBeQualified = false
                } else if clauseTerminators.contains(word), fromDepths.contains(depth) {
                    fromDepths.remove(depth)
                    expectsSource = false
                    sourceCanBeQualified = false
                } else if word == "FROM" || word == "JOIN" {
                    fromDepths.insert(depth)
                    expectsSource = true
                    sourceCanBeQualified = false
                } else if expectsSource {
                    expectsSource = false
                    sourceCanBeQualified = true
                } else {
                    sourceCanBeQualified = false
                }
            case let .quotedIdentifier(identifier):
                if dangerousSQLName(identifier), expectsSource || isFunctionCall {
                    return true
                }
                if expectsSource {
                    expectsSource = false
                    sourceCanBeQualified = true
                } else {
                    sourceCanBeQualified = false
                }
            case let .string(value):
                if expectsSource, dangerousSQLName(value.uppercased()) {
                    return true
                }
                sourceCanBeQualified = expectsSource
                expectsSource = false
            case let .symbol(symbol):
                switch symbol {
                case 40:
                    depth += 1
                    if expectsSource {
                        fromDepths.insert(depth)
                    }
                    sourceCanBeQualified = false
                case 41:
                    depth = max(0, depth - 1)
                    fromDepths = fromDepths.filter { $0 <= depth }
                    expectsSource = false
                    sourceCanBeQualified = true
                case 44:
                    expectsSource = fromDepths.contains(depth)
                    sourceCanBeQualified = false
                case 46:
                    expectsSource = sourceCanBeQualified
                    sourceCanBeQualified = false
                default:
                    break
                }
            }
        }
        return false
    }

    private static func dangerousSQLName(_ name: String) -> Bool {
        name.hasPrefix("PRAGMA_")
            || name == "EVAL"
            || name == "FTS3_TOKENIZER"
            || name == "LOAD_EXTENSION"
            || name == "WRITEFILE"
    }

    private static func isSQLIdentifierStart(_ byte: UInt8) -> Bool {
        byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isSQLIdentifierByte(_ byte: UInt8) -> Bool {
        isSQLIdentifierStart(byte) || (48...57).contains(byte) || byte >= 128
    }

    private static func validDecimal(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.range(
            of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#,
            options: .regularExpression) != nil
    }

    private static func validTextValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("\0")
    }

    private static func validateConsistency(
        _ consistency: DatabaseConsistencyPreference,
        failure: DatabaseAdapterFailure
    ) throws {
        switch consistency {
        case .productDefault, .bestEffort, .eventual:
            return
        case .session, .snapshot, .strong:
            throw failure
        }
    }

    private static func checkExecution(deadline: Date?) throws {
        if Task.isCancelled {
            throw CancellationError()
        }
        if let deadline, deadline <= Date() {
            throw SQLiteDatabaseAdapterExecutionInterruption.deadlineExceeded
        }
    }

    private static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func qualified(_ source: String, _ column: String) -> String {
        "\(quote(source)).\(quote(column))"
    }

    private static func fold(_ identifier: String) -> String {
        let scalars = identifier.unicodeScalars.map { scalar in
            (65...90).contains(scalar.value)
                ? UnicodeScalar(scalar.value + 32) ?? scalar
                : scalar
        }
        return String(String.UnicodeScalarView(scalars))
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
            (.explain, .familyRequired),
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
                    availability: .available),
                DatabaseCapabilityStatus(
                    id: .browse,
                    requirement: .sharedRequired,
                    availability: .available),
                DatabaseCapabilityStatus(
                    id: .query,
                    requirement: .familyRequired,
                    availability: .available),
                DatabaseCapabilityStatus(
                    id: .queryCancellation,
                    requirement: .sharedRequired,
                    availability: .available),
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
            pagingModes: [.offset],
            mutationModes: [.unsupported],
            transactionModes: [.none],
            cancellationModes: [.cooperative],
            safetyLimitations: [
                "Offset pages can shift when another connection changes the database.",
                "SQL query results are limited to one bounded page.",
                "Session, snapshot, and strong consistency are unavailable.",
                "Mutation, streaming, object discovery, and explain are not implemented.",
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
        configuration.prepareDatabase { database in
            _ = sqlite3_limit(database.sqliteConnection, SQLITE_LIMIT_LENGTH, 8_388_608)
            if enforceQueryOnly {
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
