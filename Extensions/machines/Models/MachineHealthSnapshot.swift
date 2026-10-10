import Foundation

public struct MachineHealthSnapshot: Codable, Equatable, Sendable {
    public struct Machine: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let reachable: Bool
        public let detail: String?

        public init(id: String, name: String, reachable: Bool, detail: String?) {
            self.id = id
            self.name = name
            self.reachable = reachable
            self.detail = detail
        }
    }

    public let checkedAt: Date
    public let machines: [Machine]
    public let skipped: Bool

    public init(checkedAt: Date, machines: [Machine], skipped: Bool) {
        self.checkedAt = checkedAt
        self.machines = machines
        self.skipped = skipped
    }
}
