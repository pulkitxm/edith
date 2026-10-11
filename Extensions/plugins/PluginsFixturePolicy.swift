import Foundation

enum PluginsFixturePolicyError: Error { case invalid, unavailable }

@MainActor final class PluginsFixturePolicy {
    private var stopped = false
    private let requireCurrent: () throws -> Void

    init(requireCurrent: @escaping () throws -> Void) throws {
        try requireCurrent()
        self.requireCurrent = requireCurrent
    }

    func stop() { stopped = true }

    func perform(
        _ command: String, payload: Data, skillIDs: Set<String>, agentIDs: Set<String>,
        execute: () async throws -> Data
    ) async throws -> Data {
        try current()
        try Self.validate(command, payload: payload, skillIDs: skillIDs, agentIDs: agentIDs)
        let result = try await execute()
        try current()
        return result
    }

    private func current() throws {
        guard !stopped else { throw PluginsFixturePolicyError.unavailable }
        try Task.checkCancellation()
        try requireCurrent()
    }

    static func validate(
        _ command: String, payload: Data, skillIDs: Set<String>, agentIDs: Set<String>
    ) throws {
        if command == "surface.snapshot" || command == "surface.perform" { return }
        guard command == "plugins.ui.action", payload.count <= 8192,
            let fields = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let action = fields["action"] as? String
        else { throw PluginsFixturePolicyError.invalid }
        let keys = Set(fields.keys)
        switch action {
        case "snapshot", "discover":
            guard keys == ["action"] else { throw PluginsFixturePolicyError.invalid }
        case "present":
            guard keys == ["action", "skillID"] || keys == ["action", "skillID", "agentID"],
                let skill = fields["skillID"] as? String, skillIDs.contains(skill)
            else { throw PluginsFixturePolicyError.invalid }
            if keys.contains("agentID") {
                guard let agent = fields["agentID"] as? String, agentIDs.contains(agent) else {
                    throw PluginsFixturePolicyError.invalid
                }
            }
        case "select":
            guard keys == ["action", "agentID", "enabled"],
                let agent = fields["agentID"] as? String, agentIDs.contains(agent),
                let enabled = fields["enabled"] as? NSNumber,
                String(cString: enabled.objCType) == "c",
                fields["enabled"] is Bool
            else { throw PluginsFixturePolicyError.invalid }
        default: throw PluginsFixturePolicyError.invalid
        }
    }
}
