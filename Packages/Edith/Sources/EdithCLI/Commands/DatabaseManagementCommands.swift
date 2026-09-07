import ArgumentParser
import EdithDatabase
import Foundation

extension DatabaseCLI {
    static let maximumSavedQueryLimit = 500
    static let maximumSavedQueryOffset = 1_000_000
    static let maximumSavedQueryBytes = 8 * 1_024 * 1_024

    static func savedQueryID(_ value: String) throws -> DatabaseSavedQueryID {
        guard let identifier = UUID(uuidString: value) else {
            throw CLIFailure.usage(
                "query-id must be a UUID",
                hint: "run `ed database saved-queries list --json` to see query IDs")
        }
        return DatabaseSavedQueryID(rawValue: identifier)
    }

    static func savedQueryLanguage(_ value: String) throws -> DatabaseSavedQueryLanguage {
        try resolveOne(
            value,
            from: DatabaseSavedQueryLanguage.allCases,
            name: "saved query language"
        ) { $0.rawValue }
    }

    static func savedQueryLanguages(_ values: [String]) throws
        -> Set<DatabaseSavedQueryLanguage>
    {
        Set(try values.map(savedQueryLanguage))
    }

    static func savedQueryOrder(_ value: String) throws -> DatabaseSavedQueryOrder {
        try resolveOne(value, from: DatabaseSavedQueryOrder.allCases, name: "saved query order") {
            $0.rawValue
        }
    }

    static func loadConnection(_ connectionID: DatabaseConnectionID) async throws
        -> DatabaseConnectionDefinition
    {
        let response = try await send(
            .connectionGet(DatabaseConnectionGetRequest(connectionID: connectionID)))
        let payload = try payload(
            response.connectionGetResult,
            response: response,
            expected: .connectionGet)
        guard let connection = payload.connection else {
            throw CLIFailure.notFound(
                "no saved database connection with id \(connectionID.rawValue.uuidString)",
                hint: "run `ed database connections list --json` to see connection IDs")
        }
        return connection
    }

    static func savedQuerySummaryJSON(_ query: DatabaseSavedQuery) -> JSONValue {
        .object([
            "id": .string(query.id.rawValue.uuidString.lowercased()),
            "connectionID": query.connectionID.map {
                .string($0.rawValue.uuidString.lowercased())
            } ?? .null,
            "name": .string(query.name),
            "language": .string(query.language.rawValue),
            "tags": .strings(query.tags),
            "favorite": .bool(query.isFavorite),
            "createdAt": .date(query.createdAt),
            "updatedAt": .date(query.updatedAt),
        ])
    }

    static func savedQueryJSON(_ query: DatabaseSavedQuery) -> JSONValue {
        guard case .object(var fields) = savedQuerySummaryJSON(query) else { return .null }
        fields["text"] = .string(query.text)
        return .object(fields)
    }

    static func editedConnection(
        _ connection: DatabaseConnectionDefinition,
        environmentKind: DatabaseEnvironmentKind?,
        environmentLabel: String?,
        protection: DatabaseEnvironmentProtection?,
        readOnlyPolicy: DatabaseReadOnlyPolicy?,
        productionPolicy: DatabaseProductionPolicy?,
        group: String?,
        clearGroup: Bool,
        tags: [String]?,
        color: String?,
        clearColor: Bool,
        favorite: Bool?
    ) -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            version: connection.version,
            id: connection.id,
            displayName: connection.displayName,
            productHint: connection.productHint,
            location: connection.location,
            username: connection.username,
            namespaces: connection.namespaces,
            deploymentMode: connection.deploymentMode,
            authentication: connection.authentication,
            tls: connection.tls,
            tunnel: connection.tunnel,
            limits: connection.limits,
            readOnlyPolicy: readOnlyPolicy ?? connection.readOnlyPolicy,
            productionPolicy: productionPolicy ?? connection.productionPolicy,
            environment: DatabaseEnvironmentMetadata(
                kind: environmentKind ?? connection.environment.kind,
                label: environmentLabel ?? connection.environment.label,
                protection: protection ?? connection.environment.protection),
            group: clearGroup ? nil : group ?? connection.group,
            tags: tags ?? connection.tags,
            color: clearColor ? nil : color ?? connection.color,
            isFavorite: favorite ?? connection.isFavorite,
            options: connection.options,
            createdAt: connection.createdAt,
            updatedAt: connection.updatedAt,
            lastTestedAt: connection.lastTestedAt,
            lastUsedAt: connection.lastUsedAt)
    }
}

struct DatabaseConnectionsEditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit saved connection metadata and safety policies.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Environment kind.")
    var environment: String?

    @Option(name: .customLong("environment-label"), help: "Human-readable environment label.")
    var environmentLabel: String?

    @Option(name: .long, help: "Environment protection policy.")
    var protection: String?

    @Option(name: .customLong("read-only"), help: "Read-only policy.")
    var readOnly: String?

    @Option(name: .customLong("production-policy"), help: "Mutation policy.")
    var productionPolicy: String?

    @Option(name: .long, help: "Connection group.")
    var group: String?

    @Flag(name: .customLong("clear-group"), help: "Remove the connection group.")
    var clearGroup = false

    @Option(name: .long, help: "Replace connection tags. Repeat for several tags.")
    var tag: [String] = []

    @Flag(name: .customLong("clear-tags"), help: "Remove all connection tags.")
    var clearTags = false

    @Option(name: .long, help: "Connection color value.")
    var color: String?

    @Flag(name: .customLong("clear-color"), help: "Remove the connection color.")
    var clearColor = false

    @Flag(name: .long, help: "Mark the connection as a favorite.")
    var favorite = false

    @Flag(name: .customLong("not-favorite"), help: "Remove the connection from favorites.")
    var notFavorite = false

    @Argument(help: "The saved connection UUID.")
    var connectionID: String

    func run() async throws {
        try await execute {
            guard !(group != nil && clearGroup), !(color != nil && clearColor),
                !(favorite && notFavorite), !(clearTags && !tag.isEmpty)
            else {
                throw CLIFailure.usage("conflicting database connection edit options")
            }
            let hasChange =
                environment != nil || environmentLabel != nil || protection != nil
                || readOnly != nil || productionPolicy != nil || group != nil || clearGroup
                || !tag.isEmpty || clearTags || color != nil || clearColor || favorite
                || notFavorite
            guard hasChange else {
                throw CLIFailure.usage("provide at least one database connection edit option")
            }
            let identifier = try DatabaseCLI.connectionID(connectionID)
            let current = try await DatabaseCLI.loadConnection(identifier)
            let changed = DatabaseCLI.editedConnection(
                current,
                environmentKind: try environment.map(DatabaseCLI.environment),
                environmentLabel: environmentLabel,
                protection: try protection.map(DatabaseCLI.protection),
                readOnlyPolicy: try readOnly.map(DatabaseCLI.readOnlyPolicy),
                productionPolicy: try productionPolicy.map(DatabaseCLI.productionPolicy),
                group: group,
                clearGroup: clearGroup,
                tags: clearTags ? [] : tag.isEmpty ? nil : tag,
                color: color,
                clearColor: clearColor,
                favorite: favorite ? true : notFavorite ? false : nil)
            let response = try await DatabaseCLI.send(
                .connectionEdit(
                    DatabaseConnectionEditRequest(
                        connectionID: identifier,
                        connection: changed)))
            let payload = try DatabaseCLI.payload(
                response.connectionEditResult,
                response: response,
                expected: .connectionEdit)
            if json {
                CLIOut.json(DatabaseCLI.connectionJSON(payload.connection))
            } else {
                CLIOut.out("updated \(payload.connection.displayName)")
                CLIOut.out("id: \(payload.connection.id.rawValue.uuidString.lowercased())")
            }
        }
    }
}

struct DatabaseConnectionsDuplicateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "duplicate",
        abstract: "Duplicate a saved database connection.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The saved connection UUID.")
    var connectionID: String

    @Argument(help: "Name for the duplicate.")
    var name: String

    func run() async throws {
        try await execute {
            let identifier = try DatabaseCLI.connectionID(connectionID)
            let response = try await DatabaseCLI.send(
                .connectionDuplicate(
                    DatabaseConnectionDuplicateRequest(
                        connectionID: identifier,
                        displayName: name)))
            let payload = try DatabaseCLI.payload(
                response.connectionDuplicateResult,
                response: response,
                expected: .connectionDuplicate)
            if json {
                CLIOut.json(
                    .object([
                        "sourceConnectionID": .string(
                            payload.sourceConnectionID.rawValue.uuidString.lowercased()),
                        "connection": DatabaseCLI.connectionJSON(payload.connection),
                        "sharesCredentials": .bool(payload.sharesCredentials),
                        "sharedCredentialCount": .int(
                            payload.sharedCredentialReferences.count),
                    ]))
            } else {
                CLIOut.out("duplicated \(payload.connection.displayName)")
                CLIOut.out("id: \(payload.connection.id.rawValue.uuidString.lowercased())")
                if payload.sharesCredentials {
                    CLIOut.note("the duplicate shares stored credentials with the source")
                }
            }
        }
    }
}

struct DatabaseConnectionsRenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a saved database connection.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The saved connection UUID.")
    var connectionID: String

    @Argument(help: "New connection name.")
    var name: String

    func run() async throws {
        try await execute {
            let identifier = try DatabaseCLI.connectionID(connectionID)
            let response = try await DatabaseCLI.send(
                .connectionRename(
                    DatabaseConnectionRenameRequest(
                        connectionID: identifier,
                        displayName: name)))
            let payload = try DatabaseCLI.payload(
                response.connectionRenameResult,
                response: response,
                expected: .connectionRename)
            if json {
                CLIOut.json(DatabaseCLI.connectionJSON(payload.connection))
            } else {
                CLIOut.out("renamed \(payload.connection.displayName)")
            }
        }
    }
}

struct DatabaseConnectionsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a saved database connection.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Confirm permanent deletion without prompting.")
    var yes = false

    @Argument(help: "The saved connection UUID.")
    var connectionID: String

    func run() async throws {
        try await execute {
            guard yes else {
                throw CLIFailure.usage(
                    "database connection deletion requires --yes",
                    hint: "review the connection with `ed database connections get \(connectionID)`"
                )
            }
            let identifier = try DatabaseCLI.connectionID(connectionID)
            let response = try await DatabaseCLI.send(
                .connectionDelete(DatabaseConnectionDeleteRequest(connectionID: identifier)))
            let payload = try DatabaseCLI.payload(
                response.connectionDeleteResult,
                response: response,
                expected: .connectionDelete)
            if json {
                CLIOut.json(
                    .object([
                        "connectionID": .string(
                            payload.connectionID.rawValue.uuidString.lowercased()),
                        "deleted": .bool(payload.deleted),
                        "disconnected": .bool(payload.disconnected),
                    ]))
            } else {
                CLIOut.out(payload.deleted ? "deleted" : "not found")
                CLIOut.out("disconnected: \(payload.disconnected ? "yes" : "no")")
            }
        }
    }
}

struct DatabaseSavedQueriesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "saved-queries",
        abstract: "Manage reusable database queries.",
        subcommands: [
            DatabaseSavedQueriesListCommand.self,
            DatabaseSavedQueriesGetCommand.self,
            DatabaseSavedQueriesSaveCommand.self,
            DatabaseSavedQueriesDuplicateCommand.self,
            DatabaseSavedQueriesRenameCommand.self,
            DatabaseSavedQueriesDeleteCommand.self,
        ],
        defaultSubcommand: DatabaseSavedQueriesListCommand.self)
}

struct DatabaseSavedQueriesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List saved database queries.",
        aliases: ["ls"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Match saved query names and text.")
    var search: String?

    @Option(name: .long, help: "Only queries for this saved connection UUID.")
    var connection: String?

    @Option(name: .long, help: "Only this query language. Repeat for several.")
    var language: [String] = []

    @Option(name: .long, help: "Require this tag. Repeat for several.")
    var tag: [String] = []

    @Flag(name: .customLong("favorites-only"), help: "Only favorite saved queries.")
    var favoritesOnly = false

    @Option(name: .long, help: "Sort by name, recently-updated or recently-created.")
    var order = "recently-updated"

    @Option(name: .long, help: "Return at most this many queries, from 1 through 500.")
    var limit = 100

    @Option(name: .long, help: "Skip this many matching queries.")
    var offset = 0

    func run() async throws {
        try await execute {
            guard (1...DatabaseCLI.maximumSavedQueryLimit).contains(limit) else {
                throw CLIFailure.usage("--limit must be between 1 and 500")
            }
            guard (0...DatabaseCLI.maximumSavedQueryOffset).contains(offset) else {
                throw CLIFailure.usage("--offset must be between 0 and 1000000")
            }
            let connectionID = try connection.map(DatabaseCLI.connectionID)
            let request = DatabaseSavedQueryListRequest(
                search: DatabaseSavedQuerySearch(
                    text: search,
                    connectionID: connectionID,
                    languages: try DatabaseCLI.savedQueryLanguages(language),
                    tags: Set(tag),
                    favoritesOnly: favoritesOnly,
                    order: try DatabaseCLI.savedQueryOrder(order),
                    limit: limit,
                    offset: offset))
            let response = try await DatabaseCLI.send(.savedQueryList(request))
            let payload = try DatabaseCLI.payload(
                response.savedQueryListResult,
                response: response,
                expected: .savedQueryList)
            guard !json else {
                CLIOut.json(.array(payload.queries.map(DatabaseCLI.savedQuerySummaryJSON)))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["ID", "NAME", "LANGUAGE", "CONNECTION", "FAVORITE"],
                    rows: payload.queries.map { query in
                        [
                            query.id.rawValue.uuidString.lowercased(),
                            query.name,
                            query.language.rawValue,
                            query.connectionID?.rawValue.uuidString.lowercased() ?? "all",
                            query.isFavorite ? "yes" : "",
                        ]
                    }))
        }
    }
}

struct DatabaseSavedQueriesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show one saved database query.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The saved query UUID.")
    var queryID: String

    func run() async throws {
        try await execute {
            let identifier = try DatabaseCLI.savedQueryID(queryID)
            let response = try await DatabaseCLI.send(
                .savedQueryGet(DatabaseSavedQueryGetRequest(queryID: identifier)))
            let payload = try DatabaseCLI.payload(
                response.savedQueryGetResult,
                response: response,
                expected: .savedQueryGet)
            guard let query = payload.query else {
                throw CLIFailure.notFound(
                    "no saved database query with id \(queryID)",
                    hint: "run `ed database saved-queries list --json` to see query IDs")
            }
            if json {
                CLIOut.json(DatabaseCLI.savedQueryJSON(query))
            } else {
                CLIOut.out("name: \(TextTable.oneLine(query.name))")
                CLIOut.out("language: \(query.language.rawValue)")
                CLIOut.out("query:")
                CLIOut.out(query.text)
            }
        }
    }
}

struct DatabaseSavedQueriesSaveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Save query text read from stdin or a UTF-8 file.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Existing saved query UUID to replace.")
    var id: String?

    @Option(name: .long, help: "Associate the query with one saved connection UUID.")
    var connection: String?

    @Option(name: .long, help: "Query language.")
    var language = "sql"

    @Option(name: .long, help: "Read query text from this UTF-8 file instead of stdin.")
    var file: String?

    @Option(name: .long, help: "Saved query tag. Repeat for several tags.")
    var tag: [String] = []

    @Flag(name: .long, help: "Mark the saved query as a favorite.")
    var favorite = false

    @Argument(help: "Saved query name.")
    var name: String

    func run() async throws {
        try await execute {
            let text = try DatabaseCLIEnvironment.readQueryText(file)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIFailure.usage("saved database query text cannot be empty")
            }
            guard text.utf8.count <= DatabaseCLI.maximumSavedQueryBytes else {
                throw CLIFailure.usage("saved database query text exceeds 8388608 bytes")
            }
            let now = Date()
            let query = DatabaseSavedQuery(
                id: try id.map(DatabaseCLI.savedQueryID) ?? DatabaseSavedQueryID(),
                connectionID: try connection.map(DatabaseCLI.connectionID),
                name: name,
                language: try DatabaseCLI.savedQueryLanguage(language),
                text: text,
                tags: tag,
                isFavorite: favorite,
                createdAt: now,
                updatedAt: now)
            let response = try await DatabaseCLI.send(
                .savedQuerySave(DatabaseSavedQuerySaveRequest(query: query)))
            let payload = try DatabaseCLI.payload(
                response.savedQuerySaveResult,
                response: response,
                expected: .savedQuerySave)
            if json {
                CLIOut.json(
                    .object([
                        "created": .bool(payload.created),
                        "query": DatabaseCLI.savedQueryJSON(payload.query),
                    ]))
            } else {
                CLIOut.out(payload.created ? "saved" : "updated")
                CLIOut.out("id: \(payload.query.id.rawValue.uuidString.lowercased())")
            }
        }
    }
}

struct DatabaseSavedQueriesDuplicateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "duplicate",
        abstract: "Duplicate a saved database query.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The saved query UUID.")
    var queryID: String

    @Argument(help: "Name for the duplicate.")
    var name: String

    func run() async throws {
        try await execute {
            let identifier = try DatabaseCLI.savedQueryID(queryID)
            let response = try await DatabaseCLI.send(
                .savedQueryDuplicate(
                    DatabaseSavedQueryDuplicateRequest(queryID: identifier, name: name)))
            let payload = try DatabaseCLI.payload(
                response.savedQueryDuplicateResult,
                response: response,
                expected: .savedQueryDuplicate)
            if json {
                CLIOut.json(
                    .object([
                        "sourceQueryID": .string(
                            payload.sourceQueryID.rawValue.uuidString.lowercased()),
                        "query": DatabaseCLI.savedQueryJSON(payload.query),
                    ]))
            } else {
                CLIOut.out("duplicated \(payload.query.name)")
                CLIOut.out("id: \(payload.query.id.rawValue.uuidString.lowercased())")
            }
        }
    }
}

struct DatabaseSavedQueriesRenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a saved database query.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The saved query UUID.")
    var queryID: String

    @Argument(help: "New saved query name.")
    var name: String

    func run() async throws {
        try await execute {
            let identifier = try DatabaseCLI.savedQueryID(queryID)
            let response = try await DatabaseCLI.send(
                .savedQueryRename(
                    DatabaseSavedQueryRenameRequest(queryID: identifier, name: name)))
            let payload = try DatabaseCLI.payload(
                response.savedQueryRenameResult,
                response: response,
                expected: .savedQueryRename)
            if json {
                CLIOut.json(DatabaseCLI.savedQueryJSON(payload.query))
            } else {
                CLIOut.out("renamed \(payload.query.name)")
            }
        }
    }
}

struct DatabaseSavedQueriesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a saved database query.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Confirm permanent deletion without prompting.")
    var yes = false

    @Argument(help: "The saved query UUID.")
    var queryID: String

    func run() async throws {
        try await execute {
            guard yes else {
                throw CLIFailure.usage("saved database query deletion requires --yes")
            }
            let identifier = try DatabaseCLI.savedQueryID(queryID)
            let response = try await DatabaseCLI.send(
                .savedQueryDelete(DatabaseSavedQueryDeleteRequest(queryID: identifier)))
            let payload = try DatabaseCLI.payload(
                response.savedQueryDeleteResult,
                response: response,
                expected: .savedQueryDelete)
            if json {
                CLIOut.json(
                    .object([
                        "queryID": .string(payload.queryID.rawValue.uuidString.lowercased()),
                        "deleted": .bool(payload.deleted),
                    ]))
            } else {
                CLIOut.out(payload.deleted ? "deleted" : "not found")
            }
        }
    }
}
