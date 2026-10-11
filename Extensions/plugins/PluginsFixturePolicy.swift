import CoreFoundation
import Foundation

enum PluginsFixturePolicyError: Error { case invalid, unavailable }

@MainActor final class PluginsFixturePolicy {
    private var stopped = false
    private let requireCurrent: () throws -> Void
    private let validateSurface: (String, Data) throws -> Void

    init(
        validateSurface: @escaping (String, Data) throws -> Void = { _, _ in
            throw PluginsFixturePolicyError.invalid
        },
        requireCurrent: @escaping () throws -> Void
    ) throws {
        try requireCurrent()
        self.requireCurrent = requireCurrent
        self.validateSurface = validateSurface
    }

    func stop() { stopped = true }

    func perform(
        _ command: String, payload: Data, skillIDs: Set<String>, agentIDs: Set<String>,
        execute: () async throws -> Data
    ) async throws -> Data {
        try current()
        try Self.validate(
            command, payload: payload, skillIDs: skillIDs, agentIDs: agentIDs,
            validateSurface: validateSurface)
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
        _ command: String, payload: Data, skillIDs: Set<String>, agentIDs: Set<String>,
        validateSurface: (String, Data) throws -> Void = { _, _ in
            throw PluginsFixturePolicyError.invalid
        }
    ) throws {
        if command == "surface.snapshot" || command == "surface.perform" {
            guard !payload.isEmpty, payload.count <= 131_072 else {
                throw PluginsFixturePolicyError.invalid
            }
            try validateSurface(command, payload)
            return
        }
        guard command == "plugins.ui.action", payload.count <= 8192,
            let fields = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
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
                CFGetTypeID(enabled) == CFBooleanGetTypeID()
            else { throw PluginsFixturePolicyError.invalid }
        default: throw PluginsFixturePolicyError.invalid
        }
    }
}
