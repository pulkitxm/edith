import Foundation
import Logging
import PostgresNIO

struct PostgreSQLDatabaseMutationPlan: Sendable {
    let sql: String
    let parameters: [DatabaseValue]

    init(
        sql: String,
        parameters: [DatabaseValue]
    ) throws(DatabaseAdapterFailure) {
        guard !sql.isEmpty,
            sql.utf8.count <= PostgreSQLDatabaseReadBounds.maximumCommandBytes,
            parameters.count <= PostgreSQLDatabaseReadBounds.maximumParameters
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidMutation
        }
        self.sql = sql
        self.parameters = parameters
    }
}

struct PostgreSQLDatabaseMutationResult: Sendable {
    let affectedRows: Int
}

extension PostgresNIODatabaseClient {
    func executeMutation(
        _ plan: PostgreSQLDatabaseMutationPlan
    ) async throws -> PostgreSQLDatabaseMutationResult {
        guard let connection = lock.withLock({ resource?.connection }) else {
            throw PostgreSQLDatabaseDriverFailure.connection
        }
        let logger = Logger(label: "com.edith.database.postgresql.mutation")
        do {
            try await PostgreSQLDatabaseReadDriver.drain(
                connection,
                query: PostgresQuery(unsafeSQL: "BEGIN TRANSACTION"),
                logger: logger)
            do {
                let bindings = try PostgreSQLDatabaseReadDriver.bindings(plan.parameters)
                let result = try await PostgreSQLDatabaseReadDriver.execute(
                    connection,
                    query: PostgresQuery(unsafeSQL: plan.sql, binds: bindings),
                    maximumRows: 2,
                    logger: logger)
                guard result.rows.count <= 1 else {
                    throw PostgreSQLDatabaseDriverFailure.invalidRequest
                }
                try await PostgreSQLDatabaseReadDriver.drain(
                    connection,
                    query: PostgresQuery(unsafeSQL: "COMMIT"),
                    logger: logger)
                return PostgreSQLDatabaseMutationResult(affectedRows: result.rows.count)
            } catch {
                try? await PostgreSQLDatabaseReadDriver.drain(
                    connection,
                    query: PostgresQuery(unsafeSQL: "ROLLBACK"),
                    logger: logger)
                throw error
            }
        } catch let failure as PostgreSQLDatabaseDriverFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw try PostgreSQLDatabaseDriverErrorClassifier.classify(error)
        }
    }
}
