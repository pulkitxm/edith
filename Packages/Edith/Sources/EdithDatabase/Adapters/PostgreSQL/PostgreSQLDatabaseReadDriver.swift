import Foundation
import Logging
import NIOCore
import PostgresNIO

struct PostgreSQLDatabaseReadPlan: Sendable {
    let sql: String
    let parameters: [DatabaseValue]
    let maximumRows: Int

    init(
        sql: String,
        parameters: [DatabaseValue] = [],
        maximumRows: Int
    ) throws(DatabaseAdapterFailure) {
        guard !sql.isEmpty,
            sql.utf8.count <= PostgreSQLDatabaseReadBounds.maximumCommandBytes,
            parameters.count <= PostgreSQLDatabaseReadBounds.maximumParameters,
            (1...PostgreSQLDatabaseReadBounds.maximumMetadataRows).contains(maximumRows)
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidQuery
        }
        self.sql = sql
        self.parameters = parameters
        self.maximumRows = maximumRows
    }
}

struct PostgreSQLDatabaseReadRow: Sendable {
    let cells: [PostgresCell]
}

struct PostgreSQLDatabaseReadResult: Sendable {
    let rows: [PostgreSQLDatabaseReadRow]
    let bytesReceived: UInt64
}

extension PostgresNIODatabaseClient {
    func executeRead(
        _ plan: PostgreSQLDatabaseReadPlan
    ) async throws -> PostgreSQLDatabaseReadResult {
        guard let connection = lock.withLock({ resource?.connection }) else {
            throw PostgreSQLDatabaseDriverFailure.connection
        }
        let logger = Logger(label: "com.edith.database.postgresql.read")
        do {
            try await PostgreSQLDatabaseReadDriver.drain(
                connection,
                query: PostgresQuery(unsafeSQL: "BEGIN TRANSACTION READ ONLY"),
                logger: logger)
            do {
                let bindings = try PostgreSQLDatabaseReadDriver.bindings(plan.parameters)
                let result = try await PostgreSQLDatabaseReadDriver.execute(
                    connection,
                    query: PostgresQuery(unsafeSQL: plan.sql, binds: bindings),
                    maximumRows: plan.maximumRows,
                    logger: logger)
                try await PostgreSQLDatabaseReadDriver.drain(
                    connection,
                    query: PostgresQuery(unsafeSQL: "COMMIT"),
                    logger: logger)
                return result
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

enum PostgreSQLDatabaseReadBounds {
    static let maximumPageRecords = 100
    static let maximumMetadataRows = DatabaseAdapterBounds.maximumPageFields + 1
    static let maximumParameters = 256
    static let maximumCommandBytes = 262_144
    static let maximumCellBytes = 1_048_576
    static let maximumResultBytes = 8_388_608
    static let maximumIdentifierBytes = 1_024
    static let maximumContinuationPosition: UInt64 = 10_000_000
    static let continuationLifetime: TimeInterval = 900
}

private struct PostgreSQLDatabaseTextParameter: PostgresDynamicTypeEncodable {
    let value: String
    let psqlType: PostgresDataType
    let psqlFormat: PostgresFormat = .text

    func encode<JSONEncoder: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<JSONEncoder>
    ) {
        byteBuffer.writeString(value)
    }
}

private enum PostgreSQLDatabaseReadDriver {
    static func bindings(
        _ values: [DatabaseValue]
    ) throws -> PostgresBindings {
        guard values.count <= PostgreSQLDatabaseReadBounds.maximumParameters else {
            throw PostgreSQLDatabaseDriverFailure.invalidRequest
        }
        var bindings = PostgresBindings(capacity: values.count)
        for value in values {
            try append(value, to: &bindings)
        }
        return bindings
    }

    static func execute(
        _ connection: PostgresConnection,
        query: PostgresQuery,
        maximumRows: Int,
        logger: Logger
    ) async throws -> PostgreSQLDatabaseReadResult {
        let sequence = try await connection.query(query, logger: logger)
        var iterator = sequence.makeAsyncIterator()
        var rows: [PostgreSQLDatabaseReadRow] = []
        rows.reserveCapacity(maximumRows)
        var totalBytes = 0
        while let row = try await iterator.next() {
            guard rows.count < maximumRows,
                row.count <= DatabaseAdapterBounds.maximumPageFields
            else {
                throw PostgreSQLDatabaseDriverFailure.resultTooLarge
            }
            var cells: [PostgresCell] = []
            cells.reserveCapacity(row.count)
            var names = Set<String>()
            for cell in row {
                let byteCount = cell.bytes?.readableBytes ?? 0
                guard !cell.columnName.isEmpty,
                    cell.columnName.utf8.count
                        <= PostgreSQLDatabaseReadBounds.maximumIdentifierBytes,
                    !cell.columnName.contains("\0"),
                    names.insert(cell.columnName).inserted,
                    byteCount <= PostgreSQLDatabaseReadBounds.maximumCellBytes,
                    totalBytes <= PostgreSQLDatabaseReadBounds.maximumResultBytes - byteCount
                else {
                    throw PostgreSQLDatabaseDriverFailure.resultTooLarge
                }
                totalBytes += byteCount
                cells.append(cell)
            }
            rows.append(PostgreSQLDatabaseReadRow(cells: cells))
        }
        return PostgreSQLDatabaseReadResult(
            rows: rows,
            bytesReceived: UInt64(totalBytes))
    }

    static func drain(
        _ connection: PostgresConnection,
        query: PostgresQuery,
        logger: Logger
    ) async throws {
        let sequence = try await connection.query(query, logger: logger)
        var iterator = sequence.makeAsyncIterator()
        guard try await iterator.next() == nil else {
            throw PostgreSQLDatabaseDriverFailure.server(nil)
        }
    }

    private static func append(
        _ value: DatabaseValue,
        to bindings: inout PostgresBindings
    ) throws {
        switch value {
        case .null:
            bindings.appendNull()
        case let .boolean(value):
            bindings.append(value)
        case let .signedInteger(value):
            bindings.append(value)
        case let .unsignedInteger(value):
            if let signed = Int64(exactly: value) {
                bindings.append(signed)
            } else {
                bindings.append(
                    PostgreSQLDatabaseTextParameter(
                        value: String(value),
                        psqlType: .numeric))
            }
        case let .decimal(value):
            guard PostgreSQLDatabaseReadValueSupport.validDecimal(value.rawValue) else {
                throw PostgreSQLDatabaseDriverFailure.invalidRequest
            }
            bindings.append(
                PostgreSQLDatabaseTextParameter(
                    value: value.rawValue,
                    psqlType: .numeric))
        case let .floatingPoint(value):
            guard value.isFinite else {
                throw PostgreSQLDatabaseDriverFailure.invalidRequest
            }
            bindings.append(value)
        case let .string(value):
            guard PostgreSQLDatabaseReadValueSupport.validBoundString(value) else {
                throw PostgreSQLDatabaseDriverFailure.invalidRequest
            }
            bindings.append(value)
        case let .binary(value):
            guard value.isComplete,
                value.availableBytes.count <= PostgreSQLDatabaseReadBounds.maximumCellBytes
            else {
                throw PostgreSQLDatabaseDriverFailure.invalidRequest
            }
            try bindings.append(value.availableBytes)
        case let .date(value):
            guard PostgreSQLDatabaseReadValueSupport.validTemporalText(value.text) else {
                throw PostgreSQLDatabaseDriverFailure.invalidRequest
            }
            bindings.append(
                PostgreSQLDatabaseTextParameter(
                    value: value.text,
                    psqlType: .date))
        case let .time(value):
            guard PostgreSQLDatabaseReadValueSupport.validTemporalText(value.text) else {
                throw PostgreSQLDatabaseDriverFailure.invalidRequest
            }
            bindings.append(
                PostgreSQLDatabaseTextParameter(
                    value: value.text,
                    psqlType: value.timeZoneOffsetMinutes == nil ? .time : .timetz))
        case let .timestamp(value):
            guard PostgreSQLDatabaseReadValueSupport.validTemporalText(value.text) else {
                throw PostgreSQLDatabaseDriverFailure.invalidRequest
            }
            let hasTimeZone =
                value.timeZoneIdentifier != nil
                || value.timeZoneOffsetMinutes != nil
            bindings.append(
                PostgreSQLDatabaseTextParameter(
                    value: value.text,
                    psqlType: hasTimeZone ? .timestamptz : .timestamp))
        case let .uuid(value):
            bindings.append(value)
        case .missing, .array, .object, .productSpecific:
            throw PostgreSQLDatabaseDriverFailure.invalidRequest
        }
    }
}
