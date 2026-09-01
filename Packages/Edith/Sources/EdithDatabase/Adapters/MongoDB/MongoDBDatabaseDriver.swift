import Foundation
import MongoClient
import MongoCore
import MongoKitten
import NIOCore
import NIOTransportServices

enum MongoDBDatabaseDriverFailure: Error, Equatable, Sendable {
    case authentication
    case connection
    case permission(Int?)
    case timeout
    case server(Int?)
    case responseTooLarge
}

struct MongoDBDatabaseConnectionPlan: Sendable {
    let settings: ConnectionSettings
}

struct MongoDBDatabaseReadPlan: Sendable {
    let database: String
    let collection: String
    let filter: Document
    let projection: Document?
    let sort: Document
    let limit: Int
    let batchSize: Int
    let maximumTimeMilliseconds: Int32
}

struct MongoDBDatabaseReadResult: Sendable {
    let documents: [Document]
    let hasMore: Bool
    let bytesReceived: UInt64
}

struct MongoDBDatabaseCollectionPlan: Sendable {
    let database: String
    let limit: Int
    let batchSize: Int
    let maximumTimeMilliseconds: Int32
}

struct MongoDBDatabaseCollectionResult: Sendable {
    let names: [String]
    let hasMore: Bool
}

enum MongoDBDatabaseMutationOperation: Sendable {
    case insert(Document)
    case update(filter: Document, values: Document)
    case delete(filter: Document)
}

struct MongoDBDatabaseMutationPlan: Sendable {
    let database: String
    let collection: String
    let operation: MongoDBDatabaseMutationOperation
    let maximumTimeMilliseconds: Int32
}

struct MongoDBDatabaseMutationResult: Sendable {
    let insertedCount: Int
    let matchedCount: Int
    let modifiedCount: Int
    let deletedCount: Int
}

protocol MongoDBDatabaseClient: Sendable {
    func discoverIdentity() async throws -> DatabaseProductIdentity
    func listCollections(
        _ plan: MongoDBDatabaseCollectionPlan
    ) async throws -> MongoDBDatabaseCollectionResult
    func read(_ plan: MongoDBDatabaseReadPlan) async throws -> MongoDBDatabaseReadResult
    func mutate(_ plan: MongoDBDatabaseMutationPlan) async throws -> MongoDBDatabaseMutationResult
    func disconnect() async throws
}

typealias MongoDBDatabaseClientConnector =
    @Sendable (
        MongoDBDatabaseConnectionPlan,
        DatabaseAdapterConnectionContext
    ) async throws -> any MongoDBDatabaseClient

actor MongoKittenDatabaseClient: MongoDBDatabaseClient {
    private var transport: MongoDBDatabaseConnectedTransport?
    private let identity: DatabaseProductIdentity

    private init(transport: MongoDBDatabaseConnectedTransport) {
        self.transport = transport
        identity = transport.identity
    }

    static func connect(
        _ plan: MongoDBDatabaseConnectionPlan,
        context: DatabaseAdapterConnectionContext,
        eventLoopFactory: MongoDBDatabaseEventLoopFactory = {
            NIOTSEventLoopGroup(loopCount: 1)
        },
        eventLoopShutdown: @escaping MongoDBDatabaseEventLoopShutdown = { group in
            try await group.shutdownGracefully()
        }
    ) async throws -> any MongoDBDatabaseClient {
        do {
            let transport = try await MongoDBDatabaseTransport.connect(
                plan,
                context: context,
                eventLoopFactory: eventLoopFactory,
                eventLoopShutdown: eventLoopShutdown)
            return MongoKittenDatabaseClient(transport: transport)
        } catch {
            throw try MongoDBDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func discoverIdentity() async throws -> DatabaseProductIdentity {
        guard transport != nil else {
            throw MongoDBDatabaseDriverFailure.connection
        }
        return identity
    }

    func read(_ plan: MongoDBDatabaseReadPlan) async throws -> MongoDBDatabaseReadResult {
        guard let transport else {
            throw MongoDBDatabaseDriverFailure.connection
        }
        let connection = try await transport.activeConnection()
        do {
            await connection.setDatabaseQueryTimeout(
                .milliseconds(Int64(plan.maximumTimeMilliseconds)))
            let namespace = MongoNamespace(to: plan.collection, inDatabase: plan.database)
            let response = try await connection.executeCodable(
                MongoDBFindCommand(plan: plan),
                decodeAs: MongoCursorResponse.self,
                namespace: MongoNamespace(to: "$cmd", inDatabase: plan.database),
                sessionId: connection.implicitSessionId,
                traceLabel: "DatabaseRead")
            let cursor = MongoCursor(
                reply: response.cursor,
                in: namespace,
                connection: connection,
                session: connection.implicitSession,
                transaction: nil,
                traceLabel: "DatabaseRead")
            cursor.maxTimeMS = plan.maximumTimeMilliseconds
            return try await Self.collect(
                cursor: cursor,
                limit: plan.limit,
                batchSize: plan.batchSize)
        } catch let failure as MongoDBDatabaseDriverFailure {
            throw failure
        } catch {
            throw try MongoDBDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func listCollections(
        _ plan: MongoDBDatabaseCollectionPlan
    ) async throws -> MongoDBDatabaseCollectionResult {
        guard let transport else {
            throw MongoDBDatabaseDriverFailure.connection
        }
        let connection = try await transport.activeConnection()
        do {
            await connection.setDatabaseQueryTimeout(
                .milliseconds(Int64(plan.maximumTimeMilliseconds)))
            let commandNamespace = MongoNamespace(to: "$cmd", inDatabase: plan.database)
            let response = try await connection.executeCodable(
                ListCollections(),
                decodeAs: MongoCursorResponse.self,
                namespace: commandNamespace,
                sessionId: connection.implicitSessionId,
                traceLabel: "DatabaseListCollections")
            let cursor = MongoCursor(
                reply: response.cursor,
                in: .administrativeCommand,
                connection: connection,
                session: connection.implicitSession,
                transaction: nil,
                traceLabel: "DatabaseListCollections")
            cursor.maxTimeMS = plan.maximumTimeMilliseconds
            return try await Self.collectCollections(
                cursor: cursor,
                limit: plan.limit,
                batchSize: plan.batchSize)
        } catch let failure as MongoDBDatabaseDriverFailure {
            throw failure
        } catch {
            throw try MongoDBDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func mutate(
        _ plan: MongoDBDatabaseMutationPlan
    ) async throws -> MongoDBDatabaseMutationResult {
        guard let transport else {
            throw MongoDBDatabaseDriverFailure.connection
        }
        let connection = try await transport.activeConnection()
        do {
            await connection.setDatabaseQueryTimeout(
                .milliseconds(Int64(plan.maximumTimeMilliseconds)))
            let namespace = MongoNamespace(to: "$cmd", inDatabase: plan.database)
            switch plan.operation {
            case let .insert(document):
                var command = InsertCommand(
                    documents: [document],
                    inCollection: plan.collection)
                command.ordered = true
                let reply = try await connection.executeCodable(
                    command,
                    decodeAs: InsertReply.self,
                    namespace: namespace,
                    sessionId: connection.implicitSessionId,
                    traceLabel: "DatabaseInsert")
                try Self.validateWriteReply(
                    ok: reply.ok,
                    writeErrors: reply.writeErrors,
                    writeConcernError: reply.writeConcernError)
                return MongoDBDatabaseMutationResult(
                    insertedCount: reply.insertCount,
                    matchedCount: 0,
                    modifiedCount: 0,
                    deletedCount: 0)
            case let .update(filter, values):
                var request = UpdateCommand.UpdateRequest(
                    where: filter,
                    setting: values,
                    unsetting: nil)
                request.multi = false
                request.upsert = false
                var command = UpdateCommand(
                    updates: [request],
                    inCollection: plan.collection)
                command.ordered = true
                let reply = try await connection.executeCodable(
                    command,
                    decodeAs: UpdateReply.self,
                    namespace: namespace,
                    sessionId: connection.implicitSessionId,
                    traceLabel: "DatabaseUpdate")
                try Self.validateWriteReply(
                    ok: reply.ok,
                    writeErrors: reply.writeErrors,
                    writeConcernError: reply.writeConcernError)
                return MongoDBDatabaseMutationResult(
                    insertedCount: 0,
                    matchedCount: reply.updatableCount,
                    modifiedCount: reply.updatedCount,
                    deletedCount: 0)
            case let .delete(filter):
                var command = DeleteCommand(
                    where: filter,
                    limit: .one,
                    fromCollection: plan.collection)
                command.ordered = true
                let reply = try await connection.executeCodable(
                    command,
                    decodeAs: DeleteReply.self,
                    namespace: namespace,
                    sessionId: connection.implicitSessionId,
                    traceLabel: "DatabaseDelete")
                try Self.validateWriteReply(
                    ok: reply.ok,
                    writeErrors: reply.writeErrors,
                    writeConcernError: reply.writeConcernError)
                return MongoDBDatabaseMutationResult(
                    insertedCount: 0,
                    matchedCount: 0,
                    modifiedCount: 0,
                    deletedCount: reply.deletes)
            }
        } catch let failure as MongoDBDatabaseDriverFailure {
            throw failure
        } catch {
            throw try MongoDBDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func disconnect() async throws {
        guard let transport else { return }
        try await transport.close()
        self.transport = nil
    }

    private static func validateWriteReply(
        ok: Int,
        writeErrors: [MongoWriteError]?,
        writeConcernError: WriteConcernError?
    ) throws {
        guard ok == 1,
            writeErrors?.isEmpty != false,
            writeConcernError == nil
        else {
            throw MongoDBDatabaseDriverFailure.server(nil)
        }
    }

    private static func collect(
        cursor: MongoCursor,
        limit: Int,
        batchSize: Int
    ) async throws -> MongoDBDatabaseReadResult {
        var accumulator = MongoDBDatabaseReadAccumulator(
            limit: limit,
            retainedByteLimit: 12_582_912)

        do {
            while !cursor.isDrained, accumulator.documents.count < limit {
                try Task.checkCancellation()
                let nextSize = min(batchSize, limit - accumulator.documents.count)
                let batch = try await cursor.getMore(batchSize: nextSize)
                if try accumulator.append(batch, cursorHasMore: !cursor.isDrained) { break }
            }
            accumulator.finish(cursorHasMore: !cursor.isDrained)
            if !cursor.isDrained {
                try await cursor.close()
            }
            return MongoDBDatabaseReadResult(
                documents: accumulator.documents,
                hasMore: accumulator.hasMore,
                bytesReceived: accumulator.bytesReceived)
        } catch {
            if !cursor.isDrained {
                do {
                    try await cursor.close()
                } catch {
                    throw MongoDBDatabaseDriverFailure.connection
                }
            }
            throw error
        }
    }

    private static func collectCollections(
        cursor: MongoCursor,
        limit: Int,
        batchSize: Int
    ) async throws -> MongoDBDatabaseCollectionResult {
        var names: [String] = []
        names.reserveCapacity(limit)
        var hasMore = false
        let decoder = BSONDecoder()
        do {
            while !cursor.isDrained, names.count < limit {
                try Task.checkCancellation()
                let nextSize = min(batchSize, limit - names.count)
                let documents = try await cursor.getMore(batchSize: max(1, nextSize))
                for document in documents {
                    if names.count == limit {
                        hasMore = true
                        break
                    }
                    let description = try decoder.decode(
                        CollectionDescription.self,
                        from: document)
                    names.append(description.name)
                }
            }
            hasMore = hasMore || !cursor.isDrained
            if !cursor.isDrained {
                try await cursor.close()
            }
            return MongoDBDatabaseCollectionResult(
                names: names,
                hasMore: hasMore)
        } catch {
            if !cursor.isDrained {
                do {
                    try await cursor.close()
                } catch {
                    throw MongoDBDatabaseDriverFailure.connection
                }
            }
            throw error
        }
    }
}

enum MongoDBDatabaseDriverErrorClassifier {
    static func classify(
        _ error: Error
    ) throws(CancellationError) -> MongoDBDatabaseDriverFailure {
        if error is CancellationError {
            throw CancellationError()
        }
        if error is MongoAuthenticationError {
            return .authentication
        }
        if case .connectTimeout = error as? ChannelError {
            return .timeout
        }
        if let error = error as? MongoError {
            switch error.kind {
            case .authenticationFailure:
                return .authentication
            case .queryTimeout:
                return .timeout
            case .cannotConnect, .cannotGetMore, .cannotCloseCursor:
                return .connection
            case .invalidResponse, .queryFailure:
                return .server(nil)
            }
        }
        if let error = error as? MongoGenericErrorReply {
            if error.code == 13 || error.code == 18 {
                return error.code == 18 ? .authentication : .permission(error.code)
            }
            if error.code == 50 {
                return .timeout
            }
            return .server(error.code)
        }
        if let error = error as? MongoDBDatabaseDriverFailure {
            return error
        }
        return .connection
    }
}

struct MongoDBDatabaseReadAccumulator {
    let limit: Int
    let retainedByteLimit: Int
    private(set) var documents: [Document] = []
    private(set) var hasMore = false
    private(set) var bytesReceived: UInt64 = 0
    private var retainedBytes = 0

    init(limit: Int, retainedByteLimit: Int) {
        self.limit = max(0, limit)
        self.retainedByteLimit = max(0, retainedByteLimit)
        documents.reserveCapacity(min(max(0, limit), 512))
    }

    mutating func append(_ batch: [Document], cursorHasMore: Bool) throws -> Bool {
        for document in batch {
            bytesReceived = Self.saturatingAdd(
                bytesReceived,
                UInt64(document.makeData().count))
        }
        for (index, document) in batch.enumerated() {
            let byteCount = document.makeData().count
            guard byteCount <= retainedByteLimit - retainedBytes else {
                guard !documents.isEmpty else {
                    throw MongoDBDatabaseDriverFailure.responseTooLarge
                }
                hasMore = true
                return true
            }
            documents.append(document)
            retainedBytes += byteCount
            if documents.count == limit {
                hasMore = index + 1 < batch.count || cursorHasMore
                return true
            }
        }
        return false
    }

    mutating func finish(cursorHasMore: Bool) {
        hasMore = hasMore || cursorHasMore
    }

    static func saturatingAdd(_ value: UInt64, _ addition: UInt64) -> UInt64 {
        let result = value.addingReportingOverflow(addition)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

struct MongoDBBuildInfoCommand: Encodable {
    let buildInfo: Int32 = 1
}

struct MongoDBBuildInfoResponse: Decodable {
    let version: String
    let gitVersion: String?
    let modules: [String]?
}

private struct MongoDBFindCommand: Encodable {
    let find: String
    let filter: Document
    let projection: Document?
    let sort: Document
    let limit: Int
    let batchSize: Int
    let maxTimeMS: Int32
    let readConcern: ReadConcern

    init(plan: MongoDBDatabaseReadPlan) {
        find = plan.collection
        filter = plan.filter
        projection = plan.projection
        sort = plan.sort
        limit = plan.limit
        batchSize = plan.batchSize
        maxTimeMS = plan.maximumTimeMilliseconds
        readConcern = ReadConcern(level: .local)
    }
}

enum MongoDBDatabaseDriverSupport {
    static func identity(
        handshake: ServerHandshake,
        build: MongoDBBuildInfoResponse
    ) -> DatabaseProductIdentity {
        let components = build.version.split(separator: ".", omittingEmptySubsequences: false)
        let topology: DatabaseTopology
        if handshake.msg == "isdbgrid" {
            topology = DatabaseTopology(
                kind: .shardedCluster,
                localRole: "router",
                attributes: [
                    DatabaseStringAttribute(
                        name: "maxWireVersion",
                        value: String(handshake.maxWireVersion.version))
                ])
        } else if let setName = handshake.setName {
            let members = Set(
                (handshake.hosts ?? []) + (handshake.passives ?? []) + (handshake.arbiters ?? []))
            let role =
                handshake.ismaster
                ? "primary" : (handshake.secondary == true ? "secondary" : "member")
            topology = DatabaseTopology(
                kind: .replicaSet,
                name: setName,
                localRole: role,
                nodeCount: members.isEmpty ? nil : members.count,
                replicaCount: members.isEmpty ? nil : members.count,
                attributes: [
                    DatabaseStringAttribute(
                        name: "maxWireVersion",
                        value: String(handshake.maxWireVersion.version))
                ])
        } else {
            topology = DatabaseTopology(
                kind: .standalone,
                localRole: handshake.readOnly == true ? "read-only" : "standalone",
                nodeCount: 1,
                attributes: [
                    DatabaseStringAttribute(
                        name: "maxWireVersion",
                        value: String(handshake.maxWireVersion.version))
                ])
        }
        let modules = (build.modules ?? []).prefix(64).map {
            DatabaseExtensionIdentity(name: $0)
        }
        return DatabaseProductIdentity(
            product: .mongoDB,
            version: DatabaseVersion(
                string: build.version,
                major: components.indices.contains(0) ? Int(components[0]) : nil,
                minor: components.indices.contains(1) ? Int(components[1]) : nil,
                patch: components.indices.contains(2) ? Int(components[2]) : nil),
            distribution: "MongoDB",
            topology: topology,
            modules: Array(modules))
    }
}
