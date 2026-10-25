import Foundation

public struct MachineUsageSummary: Equatable, Sendable, Identifiable {
    public var machineID: UUID
    public var connectionID: UUID
    public var name: String
    public var slug: String
    public var host: String
    public var collectedAt: Date
    public var sources: [String]
    public var days: Int
    public var cost: Double
    public var tokens: Double

    public var id: UUID { machineID }

    public init(
        machineID: UUID, name: String, slug: String, host: String, collectedAt: Date,
        sources: [String], days: Int, cost: Double, tokens: Double, connectionID: UUID? = nil
    ) {
        self.machineID = machineID
        self.connectionID = connectionID ?? machineID
        self.name = name
        self.slug = slug
        self.host = host
        self.collectedAt = collectedAt
        self.sources = sources
        self.days = days
        self.cost = cost
        self.tokens = tokens
    }
}
