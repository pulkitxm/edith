import DatabaseCore
import Foundation

struct DatabaseConnectionSummary: Identifiable, Equatable, Sendable {
    let id: DatabaseConnectionID
    let name: String
    let product: DatabaseProduct
    let environmentKind: DatabaseEnvironmentKind
    let environmentLabel: String
    let environmentProtection: DatabaseEnvironmentProtection
    let readOnlyPolicy: DatabaseReadOnlyPolicy
    let productionPolicy: DatabaseProductionPolicy
    let groupIdentity: String?
    let group: String?
    let tags: [String]
    let color: String?
    let isFavorite: Bool
    let lastUsedAt: Date?
    let defaultDatabase: String?
    let defaultSchema: String?
    let logicalDatabase: String?
    let networkEndpoints: [DatabaseNetworkEndpoint]

    init(definition: DatabaseConnectionDefinition) {
        id = definition.id
        name = DatabaseConnectionDisplayText.rendered(
            definition.displayName,
            fallback: "Untitled connection")
        product = definition.productHint
        environmentKind = definition.environment.kind
        environmentLabel = DatabaseConnectionDisplayText.rendered(
            definition.environment.label,
            fallback: definition.environment.kind.title)
        environmentProtection = definition.environment.protection
        readOnlyPolicy = definition.readOnlyPolicy
        productionPolicy = definition.productionPolicy
        groupIdentity = definition.group
        group = DatabaseConnectionDisplayText.optional(definition.group)
        tags = definition.tags.prefix(8).map {
            DatabaseConnectionDisplayText.rendered($0, fallback: "Tag", limit: 96)
        }
        color = DatabaseConnectionDisplayText.optional(definition.color)
        isFavorite = definition.isFavorite
        lastUsedAt = definition.lastUsedAt
        defaultDatabase = DatabaseConnectionDisplayText.optional(definition.namespaces.database)
        defaultSchema = DatabaseConnectionDisplayText.optional(definition.namespaces.schema)
        logicalDatabase = DatabaseConnectionDisplayText.optional(
            definition.namespaces.logicalDatabase)
        switch definition.location {
        case .network(let endpoints):
            networkEndpoints = endpoints
        case .sqlite, .memory:
            networkEndpoints = []
        }
    }

    var environmentSummary: String {
        "\(environmentKind.title), \(environmentLabel), \(environmentProtection.title)"
    }

    var readOnlySummary: String {
        readOnlyPolicy.title
    }

    var productionSummary: String {
        productionPolicy.title
    }
}
