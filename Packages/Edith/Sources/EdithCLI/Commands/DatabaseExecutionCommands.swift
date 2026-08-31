import ArgumentParser
import EdithDatabase
import Foundation

extension DatabaseCLI {
    static let maximumQueryBytes = 1_048_576
    static let maximumRenderedStringCharacters = 32_768
    static let maximumRenderedBinaryBytes = 4_096
    static let maximumRenderedCollectionItems = 256

    static func operationContext(timeoutMilliseconds: Int?) throws -> DatabaseOperationContext {
        guard let timeoutMilliseconds else { return DatabaseOperationContext() }
        guard (1...86_400_000).contains(timeoutMilliseconds) else {
            throw CLIFailure.usage("--timeout-milliseconds must be between 1 and 86400000")
        }
        return DatabaseOperationContext(
            deadline: Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000))
    }

    static func objectKind(_ value: String) throws -> DatabaseObjectKind {
        try resolveOne(value, from: DatabaseObjectKind.allCases, name: "database object kind") {
            $0.rawValue
        }
    }

    static func queryLanguage(_ value: String) throws -> DatabaseQueryLanguage {
        try resolveOne(
            value,
            from: DatabaseQueryLanguage.allCases,
            name: "database query language"
        ) { $0.rawValue }
    }

    static func target(
        connectionID: String,
        kind: String,
        path: [String],
        requiresObject: Bool
    ) throws -> DatabaseTargetIdentifier {
        let identifier = try self.connectionID(connectionID)
        let components = path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard components.count <= 32,
            components.allSatisfy({ !$0.isEmpty && $0.count <= 512 })
        else {
            throw CLIFailure.usage(
                "--path must contain at most 32 non-empty components of 512 characters each")
        }
        if requiresObject, components.isEmpty {
            throw CLIFailure.usage("pass at least one --path component")
        }
        let object =
            components.isEmpty
            ? nil
            : DatabaseObjectIdentifier(kind: try objectKind(kind), path: components)
        return DatabaseTargetIdentifier(connectionID: identifier, object: object)
    }

    static func pageRequest(limit: Int, continuation: String?) throws -> DatabasePageRequest {
        let size: DatabasePageSize
        do {
            size = try DatabasePageSize(limit)
        } catch {
            throw CLIFailure.usage("--limit must be between 1 and 2000")
        }
        let token = continuation.map(DatabaseContinuationToken.init(rawValue:))
        return DatabasePageRequest(pageSize: size, continuation: token)
    }

    static func queryText(path: String?) throws -> String {
        let source = path == "-" ? nil : path
        let text = try DatabaseCLIEnvironment.readQueryText(source)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIFailure.usage("database query input is empty")
        }
        guard text.utf8.count <= maximumQueryBytes else {
            throw CLIFailure.usage("database query input must not exceed 1048576 bytes")
        }
        return text
    }

    static func renderPage(
        _ page: DatabasePage<DatabaseRecord>,
        json: Bool,
        ndjson: Bool
    ) throws {
        guard !(json && ndjson) else {
            throw CLIFailure.usage("pass only one of --json or --ndjson")
        }
        if json {
            CLIOut.json(pageJSON(page))
            return
        }
        if ndjson {
            for record in page.records {
                CLIOut.out(
                    JSONSerializer.string(
                        .object(["type": .string("record"), "record": recordJSON(record)]),
                        pretty: false))
            }
            CLIOut.out(
                JSONSerializer.string(
                    .object([
                        "type": .string("page"),
                        "fields": .array(page.fields.map(fieldJSON)),
                        "nextContinuation": .optional(page.nextContinuation?.rawValue),
                        "metadata": pageMetadataJSON(page.metadata),
                    ]),
                    pretty: false))
            return
        }
        let names =
            page.fields.isEmpty
            ? page.records.first?.fields.map(\.name) ?? []
            : page.fields.map(\.displayName)
        let visibleNames = Array(names.prefix(12))
        let rows = page.records.map { record in
            visibleNames.map { name in
                let value = record.fields.first(where: { $0.name == name })?.value ?? .missing
                return humanValue(value)
            }
        }
        CLIOut.out(
            TextTable.render(
                headers: visibleNames.isEmpty ? ["RECORD"] : visibleNames,
                rows: visibleNames.isEmpty && !page.records.isEmpty
                    ? page.records.map { _ in ["record"] }
                    : rows))
        if names.count > visibleNames.count {
            CLIOut.note(
                "warning: human output shows the first 12 fields; use --json for all fields")
        }
        let more = page.nextContinuation == nil ? "" : ", more available"
        CLIOut.out("\(page.records.count) record(s)\(more)")
    }

    static func pageJSON(_ page: DatabasePage<DatabaseRecord>) -> JSONValue {
        .object([
            "records": .array(page.records.map(recordJSON)),
            "fields": .array(page.fields.map(fieldJSON)),
            "nextContinuation": .optional(page.nextContinuation?.rawValue),
            "metadata": pageMetadataJSON(page.metadata),
        ])
    }

    static func recordJSON(_ record: DatabaseRecord) -> JSONValue {
        .object([
            "identity": record.identity.map(recordIdentityJSON) ?? .null,
            "fields": .array(
                record.fields.prefix(maximumRenderedCollectionItems).map {
                    .object(["name": .string($0.name), "value": valueJSON($0.value)])
                }),
            "metadata": .array(
                record.metadata.prefix(maximumRenderedCollectionItems).map {
                    .object(["name": .string($0.name), "value": .string($0.value)])
                }),
        ])
    }

    static func valueJSON(_ value: DatabaseValue) -> JSONValue {
        switch value {
        case .missing:
            return .object(["kind": .string("missing")])
        case .null:
            return .null
        case .boolean(let flag):
            return .bool(flag)
        case .signedInteger(let number):
            return integerJSON(number)
        case .unsignedInteger(let number):
            return unsignedIntegerJSON(number)
        case .decimal(let number):
            return .object(["kind": .string("decimal"), "value": .string(number.rawValue)])
        case .floatingPoint(let number):
            return .double(number)
        case .string(let text):
            return boundedTextJSON(text)
        case .binary(let binary):
            let bytes = binary.availableBytes.prefix(maximumRenderedBinaryBytes)
            return .object([
                "kind": .string("binary"),
                "byteCount": unsignedIntegerJSON(binary.byteCount),
                "availableBytes": .int(bytes.count),
                "base64": .string(Data(bytes).base64EncodedString()),
                "complete": .bool(binary.isComplete),
                "truncated": .bool(binary.availableBytes.count > bytes.count),
            ])
        case .date(let date):
            return .object(["kind": .string("date"), "value": .string(date.text)])
        case .time(let time):
            return .object(["kind": .string("time"), "value": .string(time.text)])
        case .timestamp(let timestamp):
            return .object(["kind": .string("timestamp"), "value": .string(timestamp.text)])
        case .uuid(let value):
            return .string(value.uuidString.lowercased())
        case .array(let values):
            return .object([
                "kind": .string("array"),
                "values": .array(
                    values.prefix(maximumRenderedCollectionItems).map(valueJSON)),
                "truncated": .bool(values.count > maximumRenderedCollectionItems),
            ])
        case .object(let fields):
            return .object([
                "kind": .string("object"),
                "fields": .array(
                    fields.prefix(maximumRenderedCollectionItems).map {
                        .object(["name": .string($0.name), "value": valueJSON($0.value)])
                    }),
                "truncated": .bool(fields.count > maximumRenderedCollectionItems),
            ])
        case .productSpecific(let product):
            return .object([
                "kind": .string("productSpecific"),
                "product": .optional(product.product?.rawValue),
                "typeName": .string(product.typeName),
                "text": product.textRepresentation.map(boundedTextJSON) ?? .null,
                "binaryBytes": .optional(product.binaryRepresentation?.count),
            ])
        }
    }

    static func humanValue(_ value: DatabaseValue) -> String {
        switch value {
        case .missing: return ""
        case .null: return "NULL"
        case .boolean(let value): return value ? "true" : "false"
        case .signedInteger(let value): return String(value)
        case .unsignedInteger(let value): return String(value)
        case .decimal(let value): return value.rawValue
        case .floatingPoint(let value): return value.isFinite ? String(value) : "NULL"
        case .string(let value): return boundedOneLine(value)
        case .binary(let value): return "<\(value.byteCount) bytes>"
        case .date(let value): return boundedOneLine(value.text)
        case .time(let value): return boundedOneLine(value.text)
        case .timestamp(let value): return boundedOneLine(value.text)
        case .uuid(let value): return value.uuidString.lowercased()
        case .array(let value): return "<array \(value.count)>"
        case .object(let value): return "<object \(value.count)>"
        case .productSpecific(let value):
            return boundedOneLine(value.textRepresentation ?? "<\(value.typeName)>")
        }
    }

    private static func boundedTextJSON(_ text: String) -> JSONValue {
        guard text.count > maximumRenderedStringCharacters else { return .string(text) }
        return .object([
            "kind": .string("string"),
            "value": .string(String(text.prefix(maximumRenderedStringCharacters))),
            "characters": .int(text.count),
            "truncated": .bool(true),
        ])
    }

    private static func boundedOneLine(_ text: String) -> String {
        TextTable.oneLine(String(text.prefix(512)))
    }

    private static func integerJSON(_ value: Int64) -> JSONValue {
        Int(exactly: value).map(JSONValue.int) ?? .string(String(value))
    }

    private static func unsignedIntegerJSON(_ value: UInt64) -> JSONValue {
        Int(exactly: value).map(JSONValue.int) ?? .string(String(value))
    }

    private static func recordIdentityJSON(_ identity: DatabaseRecordIdentity) -> JSONValue {
        .object([
            "kind": .string(identity.kind.rawValue),
            "components": .array(identity.components.map(identityComponentJSON)),
            "concurrencyTokens": .array(identity.concurrencyTokens.map(identityComponentJSON)),
        ])
    }

    private static func identityComponentJSON(_ component: DatabaseIdentityComponent) -> JSONValue {
        .object(["name": .string(component.name), "value": valueJSON(component.value)])
    }

    private static func fieldJSON(_ field: DatabaseFieldDescriptor) -> JSONValue {
        .object([
            "path": .strings(field.path.segments),
            "displayName": .string(field.displayName),
            "typeName": .string(field.typeName),
            "nullable": .bool(field.isNullable),
            "sortable": .bool(field.isSortable),
            "filterable": .bool(field.isFilterable),
        ])
    }

    private static func pageMetadataJSON(_ metadata: DatabasePageMetadata) -> JSONValue {
        .object([
            "completeness": .object([
                "state": .string(metadata.completeness.state.rawValue),
                "reason": .optional(metadata.completeness.reason),
            ]),
            "count": .object([
                "value": metadata.count.value.map(unsignedIntegerJSON) ?? .null,
                "accuracy": .string(metadata.count.accuracy.rawValue),
            ]),
            "durationMilliseconds": metadata.timing.map {
                unsignedIntegerJSON($0.durationMilliseconds)
            } ?? .null,
            "serverDurationMilliseconds": metadata.timing?.serverDurationMilliseconds.map {
                unsignedIntegerJSON($0)
            } ?? .null,
            "bytesReceived": metadata.bytesReceived.map(unsignedIntegerJSON) ?? .null,
            "warnings": .array(
                metadata.warnings.map {
                    .object([
                        "code": .string($0.code),
                        "message": .string($0.message),
                        "severity": .string($0.severity.rawValue),
                    ])
                }),
            "partialFailures": .array(
                metadata.partialFailures.map {
                    .object([
                        "itemIndex": $0.itemIndex.map(unsignedIntegerJSON) ?? .null,
                        "itemIdentifier": .optional($0.itemIdentifier),
                        "category": .string($0.error.category.rawValue),
                        "message": .string($0.error.message),
                    ])
                }),
        ])
    }
}

struct DatabaseConnectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Open a broker session for a saved database connection.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Bound the operation deadline in milliseconds.")
    var timeoutMilliseconds: Int?

    @Argument(help: "The saved connection UUID.")
    var connectionID: String

    func run() async throws {
        try await execute {
            let identifier = try DatabaseCLI.connectionID(connectionID)
            let operation = try DatabaseCLI.operationContext(
                timeoutMilliseconds: timeoutMilliseconds)
            let response = try await DatabaseCLI.send(
                .connect(DatabaseConnectRequest(connectionID: identifier, operation: operation)))
            let payload = try DatabaseCLI.payload(
                response.connectResult, response: response, expected: .connect)
            if json {
                CLIOut.json(
                    .object([
                        "connectionID": .string(identifier.rawValue.uuidString.lowercased()),
                        "product": .string(payload.productIdentity.product.rawValue),
                        "version": .optional(payload.productIdentity.version?.string),
                        "connectedAt": .date(payload.connectedAt),
                        "operationID": .string(
                            operation.operationID.rawValue.uuidString.lowercased()),
                    ]))
            } else {
                CLIOut.out(
                    "connected \(payload.connection.displayName) as \(payload.productIdentity.product.displayName)"
                )
            }
        }
    }
}

struct DatabaseDisconnectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disconnect",
        abstract: "Close the broker session for a saved database connection.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Bound the operation deadline in milliseconds.")
    var timeoutMilliseconds: Int?

    @Argument(help: "The saved connection UUID.")
    var connectionID: String

    func run() async throws {
        try await execute {
            let identifier = try DatabaseCLI.connectionID(connectionID)
            let operation = try DatabaseCLI.operationContext(
                timeoutMilliseconds: timeoutMilliseconds)
            let response = try await DatabaseCLI.send(
                .disconnect(
                    DatabaseDisconnectRequest(connectionID: identifier, operation: operation)))
            let payload = try DatabaseCLI.payload(
                response.disconnectResult, response: response, expected: .disconnect)
            if json {
                CLIOut.json(
                    .object([
                        "connectionID": .string(identifier.rawValue.uuidString.lowercased()),
                        "disconnected": .bool(payload.disconnected),
                        "disconnectedAt": .date(payload.disconnectedAt),
                        "operationID": .string(
                            operation.operationID.rawValue.uuidString.lowercased()),
                    ]))
            } else {
                CLIOut.out(
                    payload.disconnected
                        ? "disconnected \(payload.connection.displayName)" : "already disconnected")
            }
        }
    }
}

struct DatabaseBrowseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browse",
        abstract: "Read one bounded page from a database object.")

    @Flag(name: .long, help: "Emit one JSON document on stdout.")
    var json = false

    @Flag(name: .long, help: "Emit records and page metadata as NDJSON.")
    var ndjson = false

    @Option(name: .long, help: "Database object kind.")
    var kind = "table"

    @Option(name: .long, help: "Object path component. Repeat for qualified paths.")
    var path: [String] = []

    @Option(name: .long, help: "Return between 1 and 2000 records.")
    var limit = 100

    @Option(name: .long, help: "Opaque continuation token from a prior page.")
    var continuation: String?

    @Option(name: .long, help: "Bound the operation deadline in milliseconds.")
    var timeoutMilliseconds: Int?

    @Argument(help: "The saved connection UUID.")
    var connectionID: String

    func run() async throws {
        try await execute {
            let target = try DatabaseCLI.target(
                connectionID: connectionID, kind: kind, path: path, requiresObject: true)
            let page = try DatabaseCLI.pageRequest(limit: limit, continuation: continuation)
            let operation = try DatabaseCLI.operationContext(
                timeoutMilliseconds: timeoutMilliseconds)
            let response = try await DatabaseCLI.send(
                .browse(DatabaseBrowseRequest(target: target, page: page, operation: operation)))
            let payload = try DatabaseCLI.payload(
                response.browseResult, response: response, expected: .browse)
            try DatabaseCLI.renderPage(payload.page, json: json, ndjson: ndjson)
        }
    }
}

struct DatabaseQueryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Execute one bounded read query from stdin or a UTF-8 file.")

    @Flag(name: .long, help: "Emit one JSON document on stdout.")
    var json = false

    @Flag(name: .long, help: "Emit records and page metadata as NDJSON.")
    var ndjson = false

    @Option(name: .long, help: "Query language.")
    var language = "sql"

    @Option(name: .long, help: "Read query text from this file, or pass - for stdin.")
    var file: String?

    @Option(name: .long, help: "Optional target object kind.")
    var kind = "table"

    @Option(name: .long, help: "Optional target path component. Repeat for qualified paths.")
    var path: [String] = []

    @Option(name: .long, help: "Return between 1 and 2000 records.")
    var limit = 100

    @Option(name: .long, help: "Opaque continuation token from a prior page.")
    var continuation: String?

    @Option(name: .long, help: "Bound the operation deadline in milliseconds.")
    var timeoutMilliseconds: Int?

    @Argument(help: "The saved connection UUID.")
    var connectionID: String

    func run() async throws {
        try await execute {
            guard !(json && ndjson) else {
                throw CLIFailure.usage("pass only one of --json or --ndjson")
            }
            let target = try DatabaseCLI.target(
                connectionID: connectionID, kind: kind, path: path, requiresObject: false)
            let page = try DatabaseCLI.pageRequest(limit: limit, continuation: continuation)
            let operation = try DatabaseCLI.operationContext(
                timeoutMilliseconds: timeoutMilliseconds)
            let command = try DatabaseCLI.queryText(path: file)
            let response = try await DatabaseCLI.send(
                .query(
                    DatabaseQueryRequest(
                        target: target,
                        language: try DatabaseCLI.queryLanguage(language),
                        command: command,
                        page: page,
                        operation: operation)))
            let payload = try DatabaseCLI.payload(
                response.queryResult, response: response, expected: .query)
            try DatabaseCLI.renderPage(payload.page, json: json, ndjson: ndjson)
        }
    }
}
