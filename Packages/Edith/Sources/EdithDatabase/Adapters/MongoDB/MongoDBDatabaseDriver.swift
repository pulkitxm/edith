import Foundation
import MongoClient
import MongoCore
import MongoKitten
import NIOCore
import NIOPosix

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

protocol MongoDBDatabaseClient: Sendable {
    func discoverIdentity() async throws -> DatabaseProductIdentity
    func read(_ plan: MongoDBDatabaseReadPlan) async throws -> MongoDBDatabaseReadResult
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
            MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

    func disconnect() async throws {
        guard let transport else { return }
        try await transport.close()
        self.transport = nil
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
