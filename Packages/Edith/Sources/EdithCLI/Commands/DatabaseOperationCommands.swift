import ArgumentParser
import EdithDatabase
import Foundation

extension DatabaseCLI {
    static func operationID(_ value: String) throws -> DatabaseOperationID {
        guard let identifier = UUID(uuidString: value) else {
            throw CLIFailure.usage("operation-id must be a UUID")
        }
        return DatabaseOperationID(rawValue: identifier)
    }

    static func operationStates(_ values: [String]) throws -> Set<DatabaseOperationState> {
        Set(
            try values.map {
                try resolveOne(
                    $0,
                    from: DatabaseOperationState.allCases,
                    name: "database operation state"
                ) { $0.rawValue }
            })
    }

    static func operationKinds(_ values: [String]) throws -> Set<DatabaseOperationKind> {
        let bounded = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard bounded.count <= 32,
            bounded.allSatisfy({ !$0.isEmpty && $0.count <= 256 })
        else {
            throw CLIFailure.usage(
                "--kind must contain at most 32 non-empty values of 256 characters each")
        }
        return Set(bounded.map(DatabaseOperationKind.init(rawValue:)))
    }

    static func operationBefore(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw CLIFailure.usage("--before must be an ISO 8601 timestamp")
        }
        return date
    }

    static func operationJSON(_ operation: DatabaseOperationRecordSummary) -> JSONValue {
        .object([
            "id": .string(operation.id.rawValue.uuidString.lowercased()),
            "kind": .string(operation.kind.rawValue),
            "state": .string(operation.state.rawValue),
            "connection": .object([
                "id": .string(operation.connection.id.rawValue.uuidString.lowercased()),
                "displayName": .string(operation.connection.displayName),
                "product": .string(operation.connection.productHint.rawValue),
                "environment": .string(operation.connection.environment.kind.rawValue),
            ]),
            "target": operation.target.map(targetJSON) ?? .null,
            "startedAt": .date(operation.startedAt),
            "finishedAt": .date(operation.finishedAt),
            "deadline": .date(operation.deadline),
            "progress": operation.progress.map(progressJSON) ?? .null,
            "cancellationSupport": .string(operation.cancellationSupport.rawValue),
            "retryClassification": .string(operation.retryClassification.rawValue),
            "pageCount": unsignedIntegerJSON(operation.pageCount),
            "recordCount": unsignedIntegerJSON(operation.recordCount),
            "byteCount": unsignedIntegerJSON(operation.byteCount),
            "warnings": .array(operation.warnings.map(warningJSON)),
            "partialFailures": .array(operation.partialFailures.map(partialFailureJSON)),
            "error": operation.error.map(errorJSON) ?? .null,
        ])
    }

    static func renderOperations(
        _ operations: [DatabaseOperationRecordSummary],
        json: Bool
    ) {
        if json {
            CLIOut.json(.array(operations.map(operationJSON)))
            return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["ID", "KIND", "STATE", "CONNECTION", "PROGRESS"],
                rows: operations.map {
                    [
                        $0.id.rawValue.uuidString.lowercased(),
                        boundedOneLine($0.kind.rawValue),
                        $0.state.rawValue,
                        boundedOneLine($0.connection.displayName),
                        humanProgress($0.progress),
                    ]
                }))
    }

    private static func targetJSON(_ target: DatabaseTargetIdentifier) -> JSONValue {
        .object([
            "connectionID": .string(target.connectionID.rawValue.uuidString.lowercased()),
            "object": target.object.map {
                .object([
                    "kind": .string($0.kind.rawValue),
                    "path": .array($0.path.map(JSONValue.string)),
                ])
            } ?? .null,
            "record": target.record.map(recordIdentityJSON) ?? .null,
        ])
    }

    private static func progressJSON(_ progress: DatabaseOperationProgress) -> JSONValue {
        .object([
            "kind": .string(progress.kind.rawValue),
            "completed": progress.completed.map(unsignedIntegerJSON) ?? .null,
            "total": progress.total.map(unsignedIntegerJSON) ?? .null,
            "unit": .optional(progress.unit?.rawValue),
            "message": progress.message.map(boundedTextJSON) ?? .null,
        ])
    }

    private static func warningJSON(_ warning: DatabaseWarning) -> JSONValue {
        .object([
            "code": .string(warning.code),
            "message": boundedTextJSON(warning.message),
            "severity": .string(warning.severity.rawValue),
        ])
    }

    private static func partialFailureJSON(_ failure: DatabasePartialFailure) -> JSONValue {
        .object([
            "itemIndex": failure.itemIndex.map(unsignedIntegerJSON) ?? .null,
            "itemIdentifier": .optional(failure.itemIdentifier),
            "error": errorJSON(failure.error),
        ])
    }

    private static func errorJSON(_ error: DatabaseErrorEnvelope) -> JSONValue {
        .object([
            "category": .string(error.category.rawValue),
            "message": boundedTextJSON(error.message),
            "productCode": .optional(error.productCode),
        ])
    }

    private static func humanProgress(_ progress: DatabaseOperationProgress?) -> String {
        guard let progress else { return "" }
        guard let completed = progress.completed else {
            return boundedOneLine(progress.message ?? progress.kind.rawValue)
        }
        let total = progress.total.map { "/\($0)" } ?? ""
        let unit = progress.unit.map { " \($0.rawValue)" } ?? ""
        return "\(completed)\(total)\(unit)"
    }
}

struct DatabaseOperationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "operations",
        abstract: "Inspect and cancel tracked database operations.",
        subcommands: [
            DatabaseOperationsListCommand.self,
            DatabaseOperationsGetCommand.self,
            DatabaseOperationsCancelCommand.self,
        ],
        defaultSubcommand: DatabaseOperationsListCommand.self)
}

struct DatabaseOperationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List tracked database operations.",
        aliases: ["ls"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Filter by saved connection UUID.")
    var connection: String?

    @Option(name: .long, help: "Filter by operation state. Repeat as needed.")
    var state: [String] = []

    @Option(name: .long, help: "Filter by operation kind. Repeat as needed.")
    var kind: [String] = []

    @Option(name: .long, help: "Return operations created before this ISO 8601 timestamp.")
    var before: String?

    @Option(name: .long, help: "Return between 1 and 1000 operations.")
    var limit = 200

    func run() async throws {
        try await execute {
            guard (1...1_000).contains(limit) else {
                throw CLIFailure.usage("--limit must be between 1 and 1000")
            }
            let connectionID = try connection.map(DatabaseCLI.connectionID)
            let search = DatabaseOperationHistorySearch(
                connectionID: connectionID,
                states: try DatabaseCLI.operationStates(state),
                kinds: try DatabaseCLI.operationKinds(kind),
                before: try DatabaseCLI.operationBefore(before),
                limit: limit)
            let response = try await DatabaseCLI.send(
                .operationList(DatabaseOperationListRequest(search: search)))
            let payload = try DatabaseCLI.payload(
                response.operationListResult,
                response: response,
                expected: .operationList)
            DatabaseCLI.renderOperations(payload.operations, json: json)
        }
    }
}

struct DatabaseOperationsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show one tracked database operation.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The operation UUID.")
    var operationID: String

    func run() async throws {
        try await execute {
            let identifier = try DatabaseCLI.operationID(operationID)
            let response = try await DatabaseCLI.send(
                .operationGet(DatabaseOperationGetRequest(operationID: identifier)))
            let payload = try DatabaseCLI.payload(
                response.operationGetResult,
                response: response,
                expected: .operationGet)
            guard let operation = payload.operation else {
                throw CLIFailure.notFound("database operation was not found")
            }
            if json {
                CLIOut.json(DatabaseCLI.operationJSON(operation))
            } else {
                DatabaseCLI.renderOperations([operation], json: false)
            }
        }
    }
}

struct DatabaseOperationsCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Request cancellation of one tracked database operation.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The operation UUID.")
    var operationID: String

    func run() async throws {
        try await execute {
            let identifier = try DatabaseCLI.operationID(operationID)
            let response = try await DatabaseCLI.send(
                .operationCancel(DatabaseOperationCancelRequest(operationID: identifier)))
            let payload = try DatabaseCLI.payload(
                response.operationCancelResult,
                response: response,
                expected: .operationCancel)
            if json {
                CLIOut.json(
                    .object([
                        "operationID": .string(identifier.rawValue.uuidString.lowercased()),
                        "disposition": .string(payload.disposition.rawValue),
                        "cancellationSupport": .string(payload.cancellationSupport.rawValue),
                        "operation": payload.operation.map(DatabaseCLI.operationJSON) ?? .null,
                    ]))
            } else {
                CLIOut.out("cancellation \(payload.disposition.rawValue)")
            }
        }
    }
}
