import Foundation

struct MySQLDatabaseMutationPlan: Equatable, Sendable {
    let sql: String
    let parameters: [DatabaseValue]
    let binds: [MySQLDatabaseBind]

    init(
        sql: String,
        parameters: [DatabaseValue]
    ) throws(DatabaseAdapterFailure) {
        guard !sql.isEmpty,
            sql.utf8.count <= DatabaseExecutionValidator.maximumCommandBytes,
            !sql.contains("\0"),
            parameters.count <= DatabaseExecutionValidator.maximumParameterCount
        else {
            throw MySQLDatabaseAdapterSupport.invalidMutation
        }
        let binds: [MySQLDatabaseBind]
        do {
            binds = try parameters.map(MySQLDatabaseReadSupport.bind)
        } catch {
            throw MySQLDatabaseAdapterSupport.invalidMutation
        }
        self.sql = sql
        self.parameters = parameters
        self.binds = binds
    }
}

struct MySQLDatabaseMutationResult: Equatable, Sendable {
    let affectedRows: UInt64
}

final class MySQLDatabaseMutationMetadataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64] = []

    func record(_ value: UInt64) {
        lock.withLock {
            values.append(value)
        }
    }

    func singleValue() -> UInt64? {
        lock.withLock {
            values.count == 1 ? values[0] : nil
        }
    }
}
