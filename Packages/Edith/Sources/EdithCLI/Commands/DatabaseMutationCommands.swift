import ArgumentParser
import EdithDatabase
import Foundation

private struct DatabaseMutationConfirmationDocument: Decodable {
    struct RequiredConfirmation: Decodable {
        let text: String
    }

    let token: String
    let requiredConfirmation: RequiredConfirmation
}

private struct DatabaseMutationReceiptDocument: Decodable {
    struct AcceptedMutation: Decodable {
        let operationID: String
        let serverOperationIdentifier: String
    }

    let connectionID: String
    let acceptedMutation: AcceptedMutation?
}

extension DatabaseCLI {
    static let maximumMutationDocumentBytes = 1_048_576
    static let maximumConfirmationDocumentBytes = 131_072

    static func decodeDocument<Value: Decodable>(
        _ type: Value.Type,
        path: String?,
        maximumBytes: Int,
        name: String
    ) throws -> Value {
        let source = path == "-" ? nil : path
        let text = try DatabaseCLIEnvironment.readQueryText(source)
        let data = Data(text.utf8)
        guard !data.isEmpty else {
            throw CLIFailure.usage("\(name) is empty")
        }
        guard data.count <= maximumBytes else {
            throw CLIFailure.usage("\(name) exceeds \(maximumBytes) bytes")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CLIFailure.usage("\(name) is not valid JSON for the database contract")
        }
    }

    static func encodeDocument<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CLIFailure("database document was not UTF-8")
            }
            return text
        } catch let failure as CLIFailure {
            throw failure
        } catch {
            throw CLIFailure("database document could not be encoded")
        }
    }

    static func mutationPreviewJSON(_ preview: DatabaseDestructivePreview) -> JSONValue {
        .object([
            "action": .string(preview.effect.action.rawValue),
            "connectionID": .string(
                preview.effect.connection.id.rawValue.uuidString.lowercased()),
            "connectionName": .string(preview.effect.connection.displayName),
            "context": .object([
                "kind": .string(preview.effect.context.kind.rawValue),
                "value": .string(preview.effect.context.value),
                "catalog": .optional(preview.effect.context.catalog),
                "schema": .optional(preview.effect.context.schema),
            ]),
            "target": targetJSON(preview.effect.target),
            "scope": .string(preview.effect.scope.rawValue),
            "impact": .object([
                "count": countJSON(preview.effect.impact.count),
                "description": boundedTextJSON(preview.effect.impact.description),
            ]),
            "transactionBehavior": .string(preview.effect.transactionBehavior.rawValue),
            "rollbackAvailability": .string(preview.effect.rollbackAvailability.rawValue),
            "executionMode": .string(preview.effect.executionMode.rawValue),
            "executionDigest": .string(preview.effect.executionDigest),
            "displayDigest": .string(preview.effect.displayDigest),
            "request": .object([
                "product": .string(preview.request.product.rawValue),
                "kind": .string(preview.request.kind.rawValue),
                "command": boundedTextJSON(preview.request.command),
                "parameters": .array(
                    preview.request.parameters.map {
                        .object([
                            "name": .string($0.name),
                            "valueKind": .string($0.valueKind.rawValue),
                        ])
                    }),
                "body": preview.request.body.map(valueJSON) ?? .null,
            ]),
            "warnings": .array(preview.warnings.map(warningJSON)),
            "requiredConfirmation": .object([
                "strength": .string(preview.requiredConfirmation.strength.rawValue),
                "text": .string(preview.requiredConfirmation.text),
            ]),
            "issuedAt": .date(preview.issuedAt),
            "expiresAt": .date(preview.expiresAt),
            "token": .string(preview.token.rawValue),
        ])
    }

    static func mutationApplyJSON(
        _ result: DatabaseMutationApplyResult,
        connectionID: DatabaseConnectionID,
        operationID: DatabaseOperationID
    ) -> JSONValue {
        guard case .object(var fields) = mutationApplyResultJSON(result) else { return .null }
        fields["connectionID"] = .string(connectionID.rawValue.uuidString.lowercased())
        fields["operationID"] = .string(operationID.rawValue.uuidString.lowercased())
        return .object(fields)
    }

    static func mutationApplyResultJSON(_ result: DatabaseMutationApplyResult) -> JSONValue {
        .object([
            "disposition": .string(result.disposition.rawValue),
            "effect": .string(result.effect.rawValue),
            "affectedRecords": countJSON(result.affectedRecords),
            "returnedRecords": result.returnedRecords.map(pageJSON) ?? .null,
            "acceptedMutation": result.acceptedMutation.map(acceptedMutationJSON) ?? .null,
            "partialFailures": .array(result.partialFailures.map(partialFailureJSON)),
            "error": result.error.map(errorJSON) ?? .null,
        ])
    }

    static func mutationStatusJSON(_ result: DatabaseMutationStatusResult) -> JSONValue {
        .object([
            "acceptedMutation": acceptedMutationJSON(result.acceptedMutation),
            "state": .string(result.state.rawValue),
            "progress": result.progress.map(progressJSON) ?? .null,
            "outcome": result.outcome.map(mutationApplyResultJSON) ?? .null,
            "error": result.error.map(errorJSON) ?? .null,
            "warnings": .array(result.warnings.map(warningJSON)),
        ])
    }

    static func mutationOutcomeJSON(_ result: DatabaseMutationOutcomeGetResult) -> JSONValue {
        .object([
            "operation": result.operation.map(operationJSON) ?? .null,
            "outcome": result.outcome.map(mutationApplyResultJSON) ?? .null,
        ])
    }

    static func acceptedMutationJSON(_ accepted: DatabaseAcceptedMutation) -> JSONValue {
        .object([
            "operationID": .string(accepted.operationID.rawValue.uuidString.lowercased()),
            "serverOperationIdentifier": boundedTextJSON(
                accepted.serverOperationIdentifier),
        ])
    }

    static func countJSON(_ count: DatabaseCountMetadata) -> JSONValue {
        .object([
            "value": count.value.map(unsignedIntegerJSON) ?? .null,
            "accuracy": .string(count.accuracy.rawValue),
        ])
    }

    static func mutationReceipt(path: String) throws
        -> (DatabaseConnectionID, DatabaseAcceptedMutation)
    {
        let receipt = try decodeDocument(
            DatabaseMutationReceiptDocument.self,
            path: path,
            maximumBytes: maximumConfirmationDocumentBytes,
            name: "database mutation receipt")
        guard let accepted = receipt.acceptedMutation else {
            throw CLIFailure.usage(
                "database mutation receipt has no accepted asynchronous mutation")
        }
        return (
            try connectionID(receipt.connectionID),
            DatabaseAcceptedMutation(
                operationID: try operationID(accepted.operationID),
                serverOperationIdentifier: accepted.serverOperationIdentifier)
        )
    }
}

struct DatabaseMutationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mutations",
        abstract: "Preview, apply, and reconcile destructive database work.",
        subcommands: [
            DatabaseMutationRowRequestCommand.self,
            DatabaseMutationKeyRequestCommand.self,
            DatabaseMutationPreviewCommand.self,
            DatabaseMutationApplyCommand.self,
            DatabaseMutationStatusCommand.self,
            DatabaseMutationCancelCommand.self,
            DatabaseMutationOutcomeCommand.self,
        ],
        defaultSubcommand: DatabaseMutationRowRequestCommand.self)
}

struct DatabaseMutationKeyRequestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key-request",
        abstract: "Build a safe Redis or Valkey string-key mutation request as JSON.")

    @Option(name: .long, help: "Key action: insert, update or delete.")
    var action: String

    @Option(name: .long, help: "Database product: redis or valkey.")
    var product = "redis"

    @Option(name: .long, help: "Logical database number.")
    var logicalDatabase = "0"

    @Option(name: .long, help: "Key name.")
    var key: String

    @Option(name: .long, help: "String value for insert or value update.")
    var value: String?

    @Option(name: .long, help: "Positive TTL in milliseconds, or -1 for no expiry.")
    var ttlMilliseconds: Int64?

    @Flag(name: .long, help: "Emit the mutation request as JSON.")
    var json = false

    @Argument(help: "The saved Redis or Valkey connection UUID.")
    var connectionID: String

    func run() async throws {
        try await execute {
            _ = json
            let product: DatabaseProduct
            switch self.product.lowercased() {
            case "redis": product = .redis
            case "valkey": product = .valkey
            default: throw CLIFailure.usage("--product must be redis or valkey")
            }
            guard let logicalDatabaseValue = Int(logicalDatabase), logicalDatabaseValue >= 0,
                logicalDatabaseValue.description == logicalDatabase
            else {
                throw CLIFailure.usage("--logical-database must be a non-negative integer")
            }
            let keyValue = DatabaseValue.string(key)
            let object = DatabaseObjectIdentifier(kind: .keyspace, path: [logicalDatabase])
            let connectionID = try DatabaseCLI.connectionID(connectionID)
            let record = DatabaseRecordIdentity(
                kind: .key,
                components: [DatabaseIdentityComponent(name: "key", value: keyValue)])
            let mutation: DatabaseDestructiveRequest
            switch action.lowercased() {
            case "insert":
                guard let value else {
                    throw CLIFailure.usage("insert requires --value")
                }
                mutation = try DatabaseKeyspaceMutationRequests.insertString(
                    target: DatabaseTargetIdentifier(
                        connectionID: connectionID,
                        object: object),
                    product: product,
                    key: keyValue,
                    value: .string(value),
                    ttlMilliseconds: ttlMilliseconds)
            case "update":
                let target = DatabaseTargetIdentifier(
                    connectionID: connectionID,
                    object: object,
                    record: record)
                if let value {
                    mutation = try DatabaseKeyspaceMutationRequests.updateString(
                        target: target,
                        product: product,
                        value: .string(value),
                        ttlMilliseconds: ttlMilliseconds == -1 ? nil : ttlMilliseconds,
                        preservesExistingTTL: ttlMilliseconds == nil)
                } else if let ttlMilliseconds {
                    mutation = try DatabaseKeyspaceMutationRequests.updateTTL(
                        target: target,
                        product: product,
                        ttlMilliseconds: ttlMilliseconds == -1 ? nil : ttlMilliseconds)
                } else {
                    throw CLIFailure.usage("update requires --value or --ttl-milliseconds")
                }
            case "delete":
                guard value == nil, ttlMilliseconds == nil else {
                    throw CLIFailure.usage("delete does not accept --value or --ttl-milliseconds")
                }
                mutation = try DatabaseKeyspaceMutationRequests.deleteKey(
                    target: DatabaseTargetIdentifier(
                        connectionID: connectionID,
                        object: object,
                        record: record),
                    product: product)
            default:
                throw CLIFailure.usage("--action must be insert, update or delete")
            }
            CLIOut.out(try DatabaseCLI.encodeDocument(mutation))
        }
    }
}

struct DatabaseMutationRowRequestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "row-request",
        abstract: "Build a safe PostgreSQL row mutation request as JSON.")

    @Option(name: .long, help: "Row action: insert, update or delete.")
    var action: String

    @Option(name: .long, help: "Table path component. Pass schema and table separately.")
    var path: [String] = []

    @Option(name: .long, help: "DatabaseRecordIdentity JSON file for update or delete.")
    var identity: String?

    @Option(name: .long, help: "DatabaseObjectField array JSON file for insert or update.")
    var values: String?

    @Flag(name: .long, help: "Emit the mutation request as JSON.")
    var json = false

    @Argument(help: "The saved PostgreSQL connection UUID.")
    var connectionID: String

    func run() async throws {
        try await execute {
            _ = json
            guard path.count == 2,
                path.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                throw CLIFailure.usage("row mutations require exactly two --path values")
            }
            let record = try identity.map {
                try DatabaseCLI.decodeDocument(
                    DatabaseRecordIdentity.self,
                    path: $0,
                    maximumBytes: DatabaseCLI.maximumConfirmationDocumentBytes,
                    name: "database row identity")
            }
            let fields =
                try values.map {
                    try DatabaseCLI.decodeDocument(
                        [DatabaseObjectField].self,
                        path: $0,
                        maximumBytes: DatabaseCLI.maximumMutationDocumentBytes,
                        name: "database row values")
                } ?? []
            let target = DatabaseTargetIdentifier(
                connectionID: try DatabaseCLI.connectionID(connectionID),
                object: DatabaseObjectIdentifier(kind: .table, path: path),
                record: record)
            let mutation: DatabaseDestructiveRequest
            switch action.lowercased() {
            case "insert":
                guard identity == nil, values != nil else {
                    throw CLIFailure.usage(
                        "insert requires --values and does not accept --identity")
                }
                mutation = try DatabaseRowMutationRequests.postgreSQLInsert(
                    target: target,
                    values: fields)
            case "update":
                guard identity != nil, values != nil else {
                    throw CLIFailure.usage("update requires --identity and --values")
                }
                mutation = try DatabaseRowMutationRequests.postgreSQLUpdate(
                    target: target,
                    values: fields)
            case "delete":
                guard identity != nil, values == nil else {
                    throw CLIFailure.usage(
                        "delete requires --identity and does not accept --values")
                }
                mutation = try DatabaseRowMutationRequests.postgreSQLDelete(target: target)
            default:
                throw CLIFailure.usage("--action must be insert, update or delete")
            }
            CLIOut.out(try DatabaseCLI.encodeDocument(mutation))
        }
    }
}

struct DatabaseMutationPreviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: "Preview a destructive request without applying it.")

    @Flag(name: .long, help: "Emit a reusable confirmation document as JSON.")
    var json = false

    @Option(
        name: .customLong("request"),
        help: "Read a DatabaseDestructiveRequest JSON document from this file or - for stdin.")
    var requestPath: String?

    @Option(name: .long, help: "Bound the operation deadline in milliseconds.")
    var timeoutMilliseconds: Int?

    func run() async throws {
        try await execute {
            let mutation = try DatabaseCLI.decodeDocument(
                DatabaseDestructiveRequest.self,
                path: requestPath,
                maximumBytes: DatabaseCLI.maximumMutationDocumentBytes,
                name: "database mutation request")
            let operation = try DatabaseCLI.operationContext(
                timeoutMilliseconds: timeoutMilliseconds)
            let response = try await DatabaseCLI.send(
                .mutationPreview(
                    DatabaseMutationPreviewRequest(
                        mutation: mutation,
                        operation: operation)))
            let payload = try DatabaseCLI.payload(
                response.mutationPreviewResult,
                response: response,
                expected: .mutationPreview)
            if json {
                CLIOut.json(DatabaseCLI.mutationPreviewJSON(payload.preview))
            } else {
                CLIOut.out("action: \(payload.preview.effect.action.rawValue)")
                CLIOut.out("connection: \(payload.preview.effect.connection.displayName)")
                CLIOut.out("scope: \(payload.preview.effect.scope.rawValue)")
                CLIOut.out(
                    "impact: \(TextTable.oneLine(payload.preview.effect.impact.description))")
                CLIOut.out("rollback: \(payload.preview.effect.rollbackAvailability.rawValue)")
                CLIOut.out("confirmation: \(payload.preview.requiredConfirmation.text)")
                CLIOut.out(
                    "expires: \(ISO8601DateFormatter().string(from: payload.preview.expiresAt))")
                CLIOut.note("rerun with --json and save stdout to use as the apply confirmation")
            }
        }
    }
}

struct DatabaseMutationApplyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply the exact request bound to a fresh preview.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Confirm that the preview was reviewed.")
    var yes = false

    @Option(name: .customLong("request"), help: "DatabaseDestructiveRequest JSON file.")
    var requestPath: String

    @Option(name: .long, help: "Preview JSON file emitted by mutations preview --json.")
    var confirmation: String

    @Option(name: .long, help: "Bound the operation deadline in milliseconds.")
    var timeoutMilliseconds: Int?

    func run() async throws {
        try await execute {
            guard yes else {
                throw CLIFailure.usage("database mutation apply requires --yes")
            }
            guard requestPath != confirmation else {
                throw CLIFailure.usage("apply requires distinct request and confirmation inputs")
            }
            let mutation = try DatabaseCLI.decodeDocument(
                DatabaseDestructiveRequest.self,
                path: requestPath,
                maximumBytes: DatabaseCLI.maximumMutationDocumentBytes,
                name: "database mutation request")
            let confirmation = try DatabaseCLI.decodeDocument(
                DatabaseMutationConfirmationDocument.self,
                path: confirmation,
                maximumBytes: DatabaseCLI.maximumConfirmationDocumentBytes,
                name: "database mutation confirmation")
            let operation = try DatabaseCLI.operationContext(
                timeoutMilliseconds: timeoutMilliseconds)
            let response = try await DatabaseCLI.send(
                .mutationApply(
                    DatabaseMutationApplyRequest(
                        mutation: mutation,
                        token: DatabaseConfirmationToken(rawValue: confirmation.token),
                        confirmationText: confirmation.requiredConfirmation.text,
                        operation: operation)))
            let payload = try DatabaseCLI.payload(
                response.mutationApplyResult,
                response: response,
                expected: .mutationApply)
            if json {
                CLIOut.json(
                    DatabaseCLI.mutationApplyJSON(
                        payload,
                        connectionID: mutation.target.connectionID,
                        operationID: operation.operationID))
            } else {
                CLIOut.out("disposition: \(payload.disposition.rawValue)")
                CLIOut.out("effect: \(payload.effect.rawValue)")
                CLIOut.out(
                    "affected: \(payload.affectedRecords.value.map(String.init) ?? "unknown")")
                if let accepted = payload.acceptedMutation {
                    CLIOut.out(
                        "operation: \(accepted.operationID.rawValue.uuidString.lowercased())")
                    CLIOut.note("save --json output to check or cancel this asynchronous mutation")
                }
            }
        }
    }
}

struct DatabaseMutationStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check an accepted asynchronous database mutation.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Apply JSON file containing an accepted mutation receipt.")
    var receipt: String

    @Option(name: .long, help: "Bound the operation deadline in milliseconds.")
    var timeoutMilliseconds: Int?

    func run() async throws {
        try await execute {
            let (connectionID, accepted) = try DatabaseCLI.mutationReceipt(path: receipt)
            let response = try await DatabaseCLI.send(
                .mutationStatus(
                    DatabaseMutationStatusRequest(
                        connectionID: connectionID,
                        acceptedMutation: accepted,
                        operation: try DatabaseCLI.operationContext(
                            timeoutMilliseconds: timeoutMilliseconds))))
            let payload = try DatabaseCLI.payload(
                response.mutationStatusResult,
                response: response,
                expected: .mutationStatus)
            if json {
                CLIOut.json(DatabaseCLI.mutationStatusJSON(payload))
            } else {
                CLIOut.out("state: \(payload.state.rawValue)")
                if let progress = payload.progress {
                    CLIOut.out(
                        "progress: \(progress.completed.map(String.init) ?? progress.kind.rawValue)"
                    )
                }
            }
        }
    }
}

struct DatabaseMutationCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Request cancellation of an accepted asynchronous mutation.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Confirm the cancellation request.")
    var yes = false

    @Option(name: .long, help: "Apply JSON file containing an accepted mutation receipt.")
    var receipt: String

    @Option(name: .long, help: "Bound the operation deadline in milliseconds.")
    var timeoutMilliseconds: Int?

    func run() async throws {
        try await execute {
            guard yes else {
                throw CLIFailure.usage("database mutation cancellation requires --yes")
            }
            let (connectionID, accepted) = try DatabaseCLI.mutationReceipt(path: receipt)
            let response = try await DatabaseCLI.send(
                .mutationCancel(
                    DatabaseMutationCancelRequest(
                        connectionID: connectionID,
                        acceptedMutation: accepted,
                        operation: try DatabaseCLI.operationContext(
                            timeoutMilliseconds: timeoutMilliseconds))))
            let payload = try DatabaseCLI.payload(
                response.mutationCancelResult,
                response: response,
                expected: .mutationCancel)
            if json {
                CLIOut.json(
                    .object([
                        "acceptedMutation": DatabaseCLI.acceptedMutationJSON(
                            payload.acceptedMutation),
                        "disposition": .string(payload.disposition.rawValue),
                        "status": payload.status.map(DatabaseCLI.mutationStatusJSON) ?? .null,
                    ]))
            } else {
                CLIOut.out("disposition: \(payload.disposition.rawValue)")
                if let status = payload.status {
                    CLIOut.out("state: \(status.state.rawValue)")
                }
            }
        }
    }
}

struct DatabaseMutationOutcomeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "outcome",
        abstract: "Read the durable outcome for a mutation operation.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Mutation operation UUID.")
    var operationID: String

    func run() async throws {
        try await execute {
            let identifier = try DatabaseCLI.operationID(operationID)
            let response = try await DatabaseCLI.send(
                .mutationOutcomeGet(
                    DatabaseMutationOutcomeGetRequest(operationID: identifier)))
            let payload = try DatabaseCLI.payload(
                response.mutationOutcomeGetResult,
                response: response,
                expected: .mutationOutcomeGet)
            if json {
                CLIOut.json(DatabaseCLI.mutationOutcomeJSON(payload))
            } else if let outcome = payload.outcome {
                CLIOut.out("effect: \(outcome.effect.rawValue)")
                CLIOut.out(
                    "affected: \(outcome.affectedRecords.value.map(String.init) ?? "unknown")")
            } else if let operation = payload.operation {
                CLIOut.out("state: \(operation.state.rawValue)")
                CLIOut.out("outcome: unavailable")
            } else {
                throw CLIFailure.notFound("database mutation operation was not found")
            }
        }
    }
}
