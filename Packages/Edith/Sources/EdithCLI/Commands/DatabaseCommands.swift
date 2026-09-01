import ArgumentParser
import EdithDatabase
import Foundation

struct DatabaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "database",
        abstract: "Inspect saved database connections and their capabilities.",
        subcommands: [
            DatabaseConnectionsCommand.self,
            DatabaseSavedQueriesCommand.self,
            DatabaseCapabilitiesCommand.self,
            DatabaseConnectCommand.self,
            DatabaseDisconnectCommand.self,
            DatabaseBrowseCommand.self,
            DatabaseQueryCommand.self,
            DatabaseMutationsCommand.self,
            DatabaseOperationsCommand.self,
            DatabaseMCPCommand.self,
        ],
        defaultSubcommand: DatabaseConnectionsCommand.self)
}

struct DatabaseConnectionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connections",
        abstract: "Inspect and create saved database connections.",
        subcommands: [
            DatabaseConnectionsListCommand.self,
            DatabaseConnectionsGetCommand.self,
            DatabaseConnectionsAddCommand.self,
            DatabaseConnectionsTestCommand.self,
            DatabaseConnectionsEditCommand.self,
            DatabaseConnectionsDuplicateCommand.self,
            DatabaseConnectionsRenameCommand.self,
            DatabaseConnectionsDeleteCommand.self,
        ],
        defaultSubcommand: DatabaseConnectionsListCommand.self)
}

enum DatabaseCLI {
    static let maximumConnectionLimit = 500
    static let maximumConnectionOffset = 1_000_000

    static func connectionID(_ value: String) throws -> DatabaseConnectionID {
        guard let identifier = UUID(uuidString: value) else {
            throw CLIFailure.usage(
                "connection-id must be a UUID",
                hint: "run `ed database connections list --json` to see connection IDs")
        }
        return DatabaseConnectionID(rawValue: identifier)
    }

    static func products(_ values: [String]) throws -> Set<DatabaseProduct> {
        try resolve(values, from: DatabaseProduct.allCases, name: "database product") {
            $0.rawValue
        }
    }

    static func environments(_ values: [String]) throws -> Set<DatabaseEnvironmentKind> {
        try resolve(values, from: DatabaseEnvironmentKind.allCases, name: "environment") {
            $0.rawValue
        }
    }

    static func order(_ value: String) throws -> DatabaseConnectionOrder {
        try resolveOne(value, from: DatabaseConnectionOrder.allCases, name: "connection order") {
            $0.rawValue
        }
    }

    static func product(_ value: String) throws -> DatabaseProduct {
        try resolveOne(
            value,
            from: DatabaseConnectionDraft.supportedProducts,
            name: "supported database product"
        ) { $0.rawValue }
    }

    static func environment(_ value: String) throws -> DatabaseEnvironmentKind {
        try resolveOne(value, from: DatabaseEnvironmentKind.allCases, name: "environment") {
            $0.rawValue
        }
    }

    static func protection(_ value: String) throws -> DatabaseEnvironmentProtection {
        try resolveOne(
            value,
            from: DatabaseEnvironmentProtection.allCases,
            name: "environment protection"
        ) { $0.rawValue }
    }

    static func readOnlyPolicy(_ value: String) throws -> DatabaseReadOnlyPolicy {
        try resolveOne(value, from: DatabaseReadOnlyPolicy.allCases, name: "read-only policy") {
            $0.rawValue
        }
    }

    static func productionPolicy(_ value: String) throws -> DatabaseProductionPolicy {
        try resolveOne(
            value,
            from: DatabaseProductionPolicy.allCases,
            name: "production policy"
        ) { $0.rawValue }
    }

    static func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        do {
            return try await DatabaseCLIEnvironment.makeSender().send(request)
        } catch let error as DatabaseBrokerCommandClientError {
            throw transportFailure(error)
        }
    }

    static func payload<Payload: Sendable>(
        _ result: DatabaseCommandResult<Payload>?,
        response: DatabaseBrokerCommandResponse,
        expected: DatabaseBrokerCommandKind
    ) throws -> Payload {
        guard response.kind == expected, let result else {
            throw CLIFailure(
                "database broker returned \(response.kind.rawValue) for \(expected.rawValue)")
        }
        switch result.status {
        case .succeeded:
            try requireComplete(result.metadata, expected: expected)
            guard let payload = result.payload else {
                throw CLIFailure("database broker returned no payload for \(expected.rawValue)")
            }
            return payload
        case .partiallySucceeded:
            let detail = result.metadata.completeness.reason ?? result.error?.message
            throw CLIFailure(
                "database broker returned partial results for \(expected.rawValue)",
                hint: detail.map(TextTable.oneLine))
        case .failed:
            guard let error = result.error else {
                throw CLIFailure("database broker returned no error for \(expected.rawValue)")
            }
            throw commandFailure(error)
        }
    }

    private static func requireComplete(
        _ metadata: DatabaseResultMetadata,
        expected: DatabaseBrokerCommandKind
    ) throws {
        guard metadata.completeness.state == .complete else {
            throw CLIFailure(
                "database broker returned \(metadata.completeness.state.rawValue) results for \(expected.rawValue)",
                hint: metadata.completeness.reason.map(TextTable.oneLine))
        }
        guard metadata.partialFailures.isEmpty else {
            throw CLIFailure(
                "database broker returned incomplete results for \(expected.rawValue)")
        }
        for warning in metadata.warnings {
            CLIOut.note(
                "warning [\(warning.severity.rawValue)] \(TextTable.oneLine(warning.code)): \(TextTable.oneLine(warning.message))"
            )
        }
    }

    static func connectionSummaryJSON(_ connection: DatabaseConnectionDefinition) -> JSONValue {
        .object([
            "id": .string(connection.id.rawValue.uuidString.lowercased()),
            "displayName": .string(connection.displayName),
            "product": .string(connection.productHint.rawValue),
            "family": .string(connection.productHint.family.rawValue),
            "environment": environmentJSON(connection.environment),
            "deploymentMode": .string(connection.deploymentMode.rawValue),
            "readOnlyPolicy": .string(connection.readOnlyPolicy.rawValue),
            "productionPolicy": .string(connection.productionPolicy.rawValue),
            "group": .optional(connection.group),
            "tags": .strings(connection.tags),
            "color": .optional(connection.color),
            "favorite": .bool(connection.isFavorite),
            "createdAt": .date(connection.createdAt),
            "updatedAt": .date(connection.updatedAt),
            "lastTestedAt": .date(connection.lastTestedAt),
            "lastUsedAt": .date(connection.lastUsedAt),
        ])
    }

    static func connectionJSON(_ connection: DatabaseConnectionDefinition) -> JSONValue {
        var fields = connectionSummaryFields(connection)
        fields["version"] = .int(connection.version)
        fields["location"] = locationJSON(connection.location)
        fields["username"] = .optional(connection.username)
        fields["namespaces"] = namespacesJSON(connection.namespaces)
        fields["authentication"] = authenticationJSON(connection.authentication)
        fields["tls"] = tlsJSON(connection.tls)
        fields["tunnel"] = connection.tunnel.map(tunnelJSON) ?? .null
        fields["limits"] = limitsJSON(connection.limits)
        fields["options"] = .array(connection.options.map(optionJSON))
        return .object(fields)
    }

    static func capabilityResultJSON(
        connectionID: DatabaseConnectionID,
        result: DatabaseCapabilitiesResult
    ) -> JSONValue {
        .object([
            "connectionID": .string(connectionID.rawValue.uuidString.lowercased()),
            "source": .string(result.source.rawValue),
            "report": capabilityReportJSON(result.report),
        ])
    }

    static func connectionLocationText(_ location: DatabaseConnectionLocation) -> String {
        switch location {
        case .network(let endpoints):
            return endpoints.map { "\($0.host):\($0.port.value)" }.joined(separator: ", ")
        case .sqlite(let sqlite):
            return sqlite.path
        case .memory(let name):
            return name.map { "memory:\($0)" } ?? "memory"
        }
    }

    static func capabilityRows(_ report: DatabaseCapabilityReport) -> [[String]] {
        report.capabilities.map { capability in
            [
                capability.id.rawValue,
                capability.availability.rawValue,
                capability.requirement.rawValue,
                capability.reason?.message ?? "",
            ]
        }
    }

    private static func connectionSummaryFields(
        _ connection: DatabaseConnectionDefinition
    ) -> [String: JSONValue] {
        guard case .object(let fields) = connectionSummaryJSON(connection) else { return [:] }
        return fields
    }

    private static func environmentJSON(
        _ environment: DatabaseEnvironmentMetadata
    ) -> JSONValue {
        .object([
            "kind": .string(environment.kind.rawValue),
            "label": .string(environment.label),
            "protection": .string(environment.protection.rawValue),
        ])
    }

    private static func locationJSON(_ location: DatabaseConnectionLocation) -> JSONValue {
        switch location {
        case .network(let endpoints):
            return .object([
                "kind": .string("network"),
                "endpoints": .array(endpoints.map(endpointJSON)),
            ])
        case .sqlite(let sqlite):
            return .object([
                "kind": .string("sqlite"),
                "path": .string(sqlite.path),
                "accessMode": .string(sqlite.accessMode.rawValue),
                "fileAccessConfigured": .bool(sqlite.fileReference != nil),
            ])
        case .memory(let name):
            return .object([
                "kind": .string("memory"),
                "name": .optional(name),
            ])
        }
    }

    private static func endpointJSON(_ endpoint: DatabaseNetworkEndpoint) -> JSONValue {
        .object([
            "host": .string(endpoint.host),
            "port": .int(endpoint.port.value),
            "role": .string(endpoint.role.rawValue),
        ])
    }

    private static func namespacesJSON(_ namespaces: DatabaseNamespaceDefaults) -> JSONValue {
        .object([
            "catalog": .optional(namespaces.catalog),
            "schema": .optional(namespaces.schema),
            "database": .optional(namespaces.database),
            "logicalDatabase": .optional(namespaces.logicalDatabase),
        ])
    }

    private static func authenticationJSON(
        _ authentication: DatabaseAuthentication
    ) -> JSONValue {
        .object([
            "kind": .string(authentication.kind.rawValue),
            "credentialsConfigured": .bool(!authentication.secretReferences.isEmpty),
        ])
    }

    private static func tlsJSON(_ tls: DatabaseTLSConfiguration) -> JSONValue {
        .object([
            "mode": .string(tls.mode.rawValue),
            "verification": .string(tls.verification.rawValue),
            "serverName": .optional(tls.serverName),
            "certificateAuthorityConfigured": .bool(tls.certificateAuthority != nil),
            "clientCertificateConfigured": .bool(tls.clientCertificate != nil),
            "clientPrivateKeyConfigured": .bool(tls.clientPrivateKey != nil),
        ])
    }

    private static func tunnelJSON(_ tunnel: DatabaseTunnelDefinition) -> JSONValue {
        .object([
            "machineIdentifier": .string(tunnel.machineIdentifier),
            "remoteEndpoint": endpointJSON(tunnel.remoteEndpoint),
            "localBindAddress": .string(tunnel.localBindAddress),
            "requestedLocalPort": tunnel.requestedLocalPort.map { .int($0.value) } ?? .null,
            "managesLifecycle": .bool(tunnel.managesLifecycle),
        ])
    }

    private static func limitsJSON(_ limits: DatabaseConnectionLimits) -> JSONValue {
        .object([
            "connectionTimeoutMilliseconds": unsignedJSON(limits.connectionTimeout.milliseconds),
            "operationTimeoutMilliseconds": unsignedJSON(limits.operationTimeout.milliseconds),
            "poolSize": .int(limits.poolSize.value),
            "idleTimeoutMilliseconds": limits.idleTimeout.map {
                unsignedJSON($0.milliseconds)
            } ?? .null,
            "keepaliveIntervalMilliseconds": limits.keepaliveInterval.map {
                unsignedJSON($0.milliseconds)
            } ?? .null,
        ])
    }

    private static func optionJSON(_ option: DatabaseNonSecretOption) -> JSONValue {
        switch option.value {
        case .boolean(let value):
            return .object([
                "name": .string(option.name), "kind": .string("boolean"),
                "value": .bool(value),
            ])
        case .integer(let value):
            return .object([
                "name": .string(option.name), "kind": .string("integer"),
                "value": signedJSON(value),
            ])
        case .string(let value):
            return .object([
                "name": .string(option.name), "kind": .string("string"),
                "value": .string(value),
            ])
        }
    }

    private static func capabilityReportJSON(_ report: DatabaseCapabilityReport) -> JSONValue {
        .object([
            "productIdentity": productIdentityJSON(report.productIdentity),
            "capabilities": .array(report.capabilities.map(capabilityJSON)),
            "permissions": .array(report.permissions.map(permissionJSON)),
            "pagingModes": .strings(report.pagingModes.map(\.rawValue)),
            "mutationModes": .strings(report.mutationModes.map(\.rawValue)),
            "transactionModes": .strings(report.transactionModes.map(\.rawValue)),
            "cancellationModes": .strings(report.cancellationModes.map(\.rawValue)),
            "importFormats": .strings(report.importFormats.map(\.rawValue)),
            "exportFormats": .strings(report.exportFormats.map(\.rawValue)),
            "explainModes": .strings(report.explainModes.map(\.rawValue)),
            "safetyLimitations": .strings(report.safetyLimitations),
            "discoveredAt": .date(report.discoveredAt),
            "expiresAt": .date(report.expiresAt),
        ])
    }

    private static func productIdentityJSON(_ identity: DatabaseProductIdentity) -> JSONValue {
        .object([
            "product": .string(identity.product.rawValue),
            "family": .string(identity.family.rawValue),
            "version": identity.version.map(versionJSON) ?? .null,
            "distribution": .optional(identity.distribution),
            "topology": topologyJSON(identity.topology),
            "serverIdentifier": .optional(identity.serverIdentifier),
            "modules": .array(identity.modules.map(extensionIdentityJSON)),
            "plugins": .array(identity.plugins.map(extensionIdentityJSON)),
            "compatibilityNotes": .strings(identity.compatibilityNotes),
        ])
    }

    private static func versionJSON(_ version: DatabaseVersion) -> JSONValue {
        .object([
            "string": .string(version.string),
            "major": .optional(version.major),
            "minor": .optional(version.minor),
            "patch": .optional(version.patch),
        ])
    }

    private static func topologyJSON(_ topology: DatabaseTopology) -> JSONValue {
        .object([
            "kind": .string(topology.kind.rawValue),
            "name": .optional(topology.name),
            "localRole": .optional(topology.localRole),
            "nodeCount": .optional(topology.nodeCount),
            "replicaCount": .optional(topology.replicaCount),
            "shardCount": .optional(topology.shardCount),
            "attributes": .array(topology.attributes.map(attributeJSON)),
        ])
    }

    private static func extensionIdentityJSON(
        _ identity: DatabaseExtensionIdentity
    ) -> JSONValue {
        .object([
            "name": .string(identity.name),
            "version": .optional(identity.version),
        ])
    }

    private static func capabilityJSON(_ capability: DatabaseCapabilityStatus) -> JSONValue {
        .object([
            "id": .string(capability.id.rawValue),
            "requirement": .string(capability.requirement.rawValue),
            "availability": .string(capability.availability.rawValue),
            "reason": capability.reason.map(capabilityReasonJSON) ?? .null,
            "limits": .array(capability.limits.map(capabilityLimitJSON)),
            "attributes": .array(capability.attributes.map(attributeJSON)),
        ])
    }

    private static func capabilityReasonJSON(
        _ reason: DatabaseCapabilityUnavailableReason
    ) -> JSONValue {
        .object([
            "category": .string(reason.category.rawValue),
            "message": .string(reason.message),
            "requiredVersion": .optional(reason.requiredVersion),
            "requiredTopology": .optional(reason.requiredTopology?.rawValue),
            "missingPermissions": .strings(reason.missingPermissions),
            "requiredExtension": .optional(reason.requiredExtension),
            "constraints": .array(reason.constraints.map(attributeJSON)),
        ])
    }

    private static func capabilityLimitJSON(_ limit: DatabaseCapabilityLimit) -> JSONValue {
        .object([
            "name": .string(limit.name),
            "value": unsignedJSON(limit.value),
            "unit": .optional(limit.unit),
        ])
    }

    private static func permissionJSON(_ permission: DatabasePermissionStatus) -> JSONValue {
        .object([
            "name": .string(permission.name),
            "granted": permission.granted.map(JSONValue.bool) ?? .null,
            "scope": .optional(permission.scope),
        ])
    }

    private static func attributeJSON(_ attribute: DatabaseStringAttribute) -> JSONValue {
        .object([
            "name": .string(attribute.name),
            "value": .string(attribute.value),
        ])
    }

    private static func transportFailure(_ error: DatabaseBrokerCommandClientError) -> CLIFailure {
        switch error {
        case .invalidRequest:
            return .usage("the database broker rejected the request")
        case .timedOut:
            return .unavailable(
                "the database broker request timed out",
                hint: "retry the read after checking database extension readiness")
        case .unavailable:
            return .unavailable(
                "the database broker is unavailable",
                hint: "run `ed extensions verify database --json`")
        case .unsafePeer:
            return .unavailable(
                "the database broker identity could not be verified",
                hint: "run `ed extensions doctor database --json`")
        case .outcomeUnknown:
            return .unavailable(
                "the database broker response was interrupted",
                hint: "the CLI did not replay the request")
        }
    }

    private static func commandFailure(_ error: DatabaseErrorEnvelope) -> CLIFailure {
        let hint = error.retry.message
        if error.category == .invalidRequest,
            error.message.localizedCaseInsensitiveContains("not found")
        {
            return .notFound(error.message, hint: hint)
        }
        switch error.category {
        case .invalidRequest, .confirmationRequired, .confirmationInvalid:
            return .usage(error.message, hint: hint)
        case .connectionFailed, .authenticationFailed, .tlsFailed, .tunnelFailed,
            .permissionDenied, .unsupported, .readOnlyViolation, .timeout, .cancelled,
            .network, .resourceLimit:
            return .unavailable(error.message, hint: hint)
        case .conflict, .server, .decoding, .partialFailure, .internalFailure:
            return CLIFailure(error.message, hint: hint)
        }
    }

    private static func resolve<Value>(
        _ values: [String],
        from supported: [Value],
        name: String,
        rawValue: (Value) -> String
    ) throws -> Set<Value> where Value: Hashable {
        Set(try values.map { try resolveOne($0, from: supported, name: name, rawValue: rawValue) })
    }

    static func resolveOne<Value>(
        _ value: String,
        from supported: [Value],
        name: String,
        rawValue: (Value) -> String
    ) throws -> Value {
        let needle = normalized(value)
        guard let resolved = supported.first(where: { normalized(rawValue($0)) == needle }) else {
            throw CLIFailure.notFound(
                "no \(name) named \(value)",
                hint: "values: " + supported.map(rawValue).joined(separator: ", "))
        }
        return resolved
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0 != "-" && $0 != "_" }
    }

    private static func unsignedJSON(_ value: UInt64) -> JSONValue {
        guard value <= UInt64(Int.max) else { return .string(String(value)) }
        return .int(Int(value))
    }

    private static func signedJSON(_ value: Int64) -> JSONValue {
        guard let converted = Int(exactly: value) else { return .string(String(value)) }
        return .int(converted)
    }
}

struct DatabaseConnectionsAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Test and save a database connection.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Database product: postgresql, sqlite, redis, valkey or mongodb.")
    var product: String

    @Option(name: .long, help: "Network host. Defaults to 127.0.0.1.")
    var host = "127.0.0.1"

    @Option(name: .long, help: "Network port. Defaults to the product's standard port.")
    var port: Int?

    @Option(name: .long, help: "SQLite database file path.")
    var path = ""

    @Option(name: .long, help: "Database username.")
    var username = ""

    @Option(name: .long, help: "Default database or Redis logical database.")
    var database = ""

    @Option(
        name: .customLong("authentication-database"),
        help: "MongoDB authentication database. Defaults to admin.")
    var authenticationDatabase = "admin"

    @Flag(
        name: .customLong("password-stdin"),
        help: "Read the database password from stdin and store it in Keychain.")
    var passwordStdin = false

    @Flag(name: .long, help: "Require TLS with full certificate verification.")
    var tls = false

    @Option(name: .long, help: "Environment kind.")
    var environment = "development"

    @Option(name: .customLong("environment-label"), help: "Human-readable environment label.")
    var environmentLabel: String?

    @Option(name: .long, help: "Environment protection policy.")
    var protection = "confirmation-required"

    @Option(name: .customLong("read-only"), help: "Read-only policy.")
    var readOnly = "required"

    @Option(name: .customLong("production-policy"), help: "Mutation policy.")
    var productionPolicy = "require-mutation-preview"

    @Argument(help: "Connection name.")
    var name: String

    func run() async throws {
        try await execute {
            let resolvedProduct = try DatabaseCLI.product(product)
            let resolvedEnvironment = try DatabaseCLI.environment(environment)
            let password = passwordStdin ? try DatabaseCLIEnvironment.readPassword() : nil
            let reference = password.map { _ in
                DatabaseSecretReference(identifier: UUID(), purpose: .password)
            }
            let draft = DatabaseConnectionDraft(
                displayName: name,
                product: resolvedProduct,
                host: host,
                port: port ?? DatabaseConnectionDraft.defaultPort(for: resolvedProduct),
                path: path,
                username: username,
                database: database,
                authenticationDatabase: authenticationDatabase,
                passwordReference: reference,
                tlsMode: tls ? .required : .disabled,
                environmentKind: resolvedEnvironment,
                environmentLabel: environmentLabel ?? resolvedEnvironment.rawValue.capitalized,
                environmentProtection: try DatabaseCLI.protection(protection),
                readOnlyPolicy: try DatabaseCLI.readOnlyPolicy(readOnly),
                productionPolicy: try DatabaseCLI.productionPolicy(productionPolicy))
            let definition = try draft.definition()
            let secretStore = try DatabaseCLIEnvironment.makeSecretStore()
            var storedReference: DatabaseSecretReference?
            do {
                if let password, let reference {
                    try await secretStore.store(Data(password.utf8), for: reference)
                    storedReference = reference
                }
                let testResponse = try await DatabaseCLI.send(
                    .connectionTest(DatabaseConnectionTestRequest(connection: definition)))
                let test = try DatabaseCLI.payload(
                    testResponse.connectionTestResult,
                    response: testResponse,
                    expected: .connectionTest)
                let saveResponse = try await DatabaseCLI.send(
                    .connectionSave(DatabaseConnectionSaveRequest(connection: definition)))
                let saved = try DatabaseCLI.payload(
                    saveResponse.connectionSaveResult,
                    response: saveResponse,
                    expected: .connectionSave)
                storedReference = nil
                if json {
                    CLIOut.json(
                        .object([
                            "connection": DatabaseCLI.connectionJSON(saved.connection),
                            "latencyMilliseconds": .int(Int(test.latencyMilliseconds)),
                            "testedProduct": .string(test.productIdentity.product.rawValue),
                        ]))
                } else {
                    CLIOut.out("saved \(saved.connection.displayName)")
                    CLIOut.out("id: \(saved.connection.id.rawValue.uuidString.lowercased())")
                    CLIOut.out("product: \(test.productIdentity.product.displayName)")
                    CLIOut.out("test latency: \(test.latencyMilliseconds) ms")
                }
            } catch {
                if let storedReference {
                    try? await secretStore.delete(storedReference)
                }
                throw error
            }
        }
    }
}

struct DatabaseConnectionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List saved database connections.",
        aliases: ["ls"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Match connection display names.")
    var search: String?

    @Option(name: .long, help: "Only this product. Repeat to include several.")
    var product: [String] = []

    @Option(name: .long, help: "Only this environment. Repeat to include several.")
    var environment: [String] = []

    @Option(name: .long, help: "Only this connection group.")
    var group: String?

    @Option(name: .long, help: "Require this tag. Repeat to require several.")
    var tag: [String] = []

    @Flag(name: .customLong("favorites-only"), help: "Only favorite connections.")
    var favoritesOnly = false

    @Option(name: .long, help: "Sort by name, recently-used, recently-updated or recently-created.")
    var order = "recently-used"

    @Option(name: .long, help: "Return at most this many connections, from 1 through 500.")
    var limit = 100

    @Option(name: .long, help: "Skip this many matching connections.")
    var offset = 0

    func run() async throws {
        try await execute {
            guard (1...DatabaseCLI.maximumConnectionLimit).contains(limit) else {
                throw CLIFailure.usage("--limit must be between 1 and 500")
            }
            guard (0...DatabaseCLI.maximumConnectionOffset).contains(offset) else {
                throw CLIFailure.usage("--offset must be between 0 and 1000000")
            }
            let search = DatabaseConnectionSearch(
                text: search,
                products: try DatabaseCLI.products(product),
                environments: try DatabaseCLI.environments(environment),
                group: group,
                tags: Set(tag),
                favoritesOnly: favoritesOnly,
                order: try DatabaseCLI.order(order),
                limit: limit,
                offset: offset)
            let response = try await DatabaseCLI.send(
                .connectionList(DatabaseConnectionListRequest(search: search)))
            let payload = try DatabaseCLI.payload(
                response.connectionListResult,
                response: response,
                expected: .connectionList)
            guard !json else {
                CLIOut.json(.array(payload.connections.map(DatabaseCLI.connectionSummaryJSON)))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["ID", "NAME", "PRODUCT", "ENVIRONMENT", "MODE", "FAVORITE"],
                    rows: payload.connections.map { connection in
                        [
                            connection.id.rawValue.uuidString.lowercased(),
                            connection.displayName,
                            connection.productHint.displayName,
                            connection.environment.label,
                            connection.readOnlyPolicy.rawValue,
                            connection.isFavorite ? "yes" : "",
                        ]
                    }))
        }
    }
}

struct DatabaseConnectionsGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show one saved database connection without credentials.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The saved connection UUID.")
    var connectionID: String

    func run() async throws {
        try await execute {
            let identifier = try DatabaseCLI.connectionID(connectionID)
            let response = try await DatabaseCLI.send(
                .connectionGet(DatabaseConnectionGetRequest(connectionID: identifier)))
            let payload = try DatabaseCLI.payload(
                response.connectionGetResult,
                response: response,
                expected: .connectionGet)
            guard let connection = payload.connection else {
                throw CLIFailure.notFound(
                    "no saved database connection with id \(connectionID)",
                    hint: "run `ed database connections list --json` to see connection IDs")
            }
            guard !json else {
                CLIOut.json(DatabaseCLI.connectionJSON(connection))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["FIELD", "VALUE"],
                    rows: [
                        ["ID", connection.id.rawValue.uuidString.lowercased()],
                        ["Name", connection.displayName],
                        ["Product", connection.productHint.displayName],
                        ["Environment", connection.environment.label],
                        ["Location", DatabaseCLI.connectionLocationText(connection.location)],
                        ["Deployment", connection.deploymentMode.rawValue],
                        ["Read only", connection.readOnlyPolicy.rawValue],
                        ["Production policy", connection.productionPolicy.rawValue],
                        ["Favorite", connection.isFavorite ? "yes" : "no"],
                    ]))
        }
    }
}

struct DatabaseCapabilitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "Show the detected capabilities for one saved connection.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Discover a fresh capability report instead of using a cache.")
    var refresh = false

    @Argument(help: "The saved connection UUID.")
    var connectionID: String

    func run() async throws {
        try await execute {
            let identifier = try DatabaseCLI.connectionID(connectionID)
            let resolution: DatabaseCapabilityResolution = refresh ? .refresh : .cachedOrDiscover
            let response = try await DatabaseCLI.send(
                .capabilities(
                    DatabaseCapabilitiesRequest(
                        connectionID: identifier,
                        resolution: resolution)))
            let payload = try DatabaseCLI.payload(
                response.capabilitiesResult,
                response: response,
                expected: .capabilities)
            guard !json else {
                CLIOut.json(
                    DatabaseCLI.capabilityResultJSON(
                        connectionID: identifier,
                        result: payload))
                return
            }
            let identity = payload.report.productIdentity
            let version = TextTable.oneLine(identity.version?.string ?? "unknown")
            CLIOut.out("product: \(identity.product.displayName) \(version)")
            CLIOut.out("topology: \(identity.topology.kind.rawValue)")
            CLIOut.out("source: \(payload.source.rawValue)")
            CLIOut.out(
                TextTable.render(
                    headers: ["CAPABILITY", "AVAILABILITY", "REQUIREMENT", "REASON"],
                    rows: DatabaseCLI.capabilityRows(payload.report)))
            for limitation in payload.report.safetyLimitations {
                CLIOut.out("safety: \(TextTable.oneLine(limitation))")
            }
        }
    }
}
