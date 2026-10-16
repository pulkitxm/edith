import Foundation
#if !FUNCTIONAL_FIXTURE_CHECKS
import Testing
@testable import PluginsExtension
#endif

@MainActor enum PluginsFixturePolicyChecks {
    static func run() async throws {
        let skills: Set<String> = ["synthetic-skill"]
        let agents: Set<String> = ["synthetic-agent"]
        let allowed = [
            "{\"action\":\"snapshot\"}", "{\"action\":\"discover\"}",
            "{\"action\":\"present\",\"skillID\":\"synthetic-skill\"}",
            "{\"action\":\"present\",\"skillID\":\"synthetic-skill\",\"agentID\":\"synthetic-agent\"}",
            "{\"action\":\"select\",\"agentID\":\"synthetic-agent\",\"enabled\":false}",
            "{\"action\":\"select\",\"agentID\":\"synthetic-agent\",\"enabled\":true}",
        ]
        for value in allowed {
            try PluginsFixturePolicy.validate(
                "plugins.ui.action", payload: Data(value.utf8), skillIDs: skills, agentIDs: agents)
        }
        let denied = [
            "{}", "[]", "null", "{", "{\"action\":true}",
            "{\"action\":\"install\"}", "{\"action\":\"download\"}",
            "{\"action\":\"snapshot\",\"enabled\":false}",
            "{\"action\":\"discover\",\"skillID\":null}",
            "{\"action\":\"present\",\"skillID\":\"unowned\"}",
            "{\"action\":\"present\",\"skillID\":\"synthetic-skill\",\"agentID\":null}",
            "{\"action\":\"select\",\"agentID\":\"unowned\",\"enabled\":true}",
            "{\"action\":\"select\",\"agentID\":\"synthetic-agent\",\"enabled\":1}",
            "{\"action\":\"select\",\"agentID\":\"synthetic-agent\",\"enabled\":\"true\"}",
            "{\"action\":\"select\",\"agentID\":\"synthetic-agent\",\"enabled\":null}",
            "{\"action\":\"select\",\"agentID\":\"synthetic-agent\",\"enabled\":false,\"skillID\":\"synthetic-skill\"}",

            #"{"action":"install","action":"snapshot"}"#,
            #"{"action":"install","a\u0063tion":"snapshot"}"#,
            #"{"action":"select","agentID":"synthetic-agent","enabled":true,"enabl\u0065d":false}"#,
            String(repeating: " ", count: 8193),
        ]
        for value in denied {
            try rejects {
                try PluginsFixturePolicy.validate(
                    "plugins.ui.action", payload: Data(value.utf8), skillIDs: skills,
                    agentIDs: agents)
            }
        }
        for command in [
            "plugins.ui.document", "plugins.ui.copy", "plugins.cli", "plugins.cli.start",
            "plugins.ui.install", "tool.execute", "unknown",
        ] {
            try rejects {
                try PluginsFixturePolicy.validate(
                    command, payload: Data(allowed[0].utf8), skillIDs: skills, agentIDs: agents)
            }
        }
        for command in ["surface.snapshot", "surface.perform"] {
            for value in ["{}", "null", "[]", "", String(repeating: " ", count: 131_073)] {
                var callbacks = 0
                let closed = try PluginsFixturePolicy(requireCurrent: {})
                do {
                    _ = try await closed.perform(
                        command, payload: Data(value.utf8), skillIDs: skills, agentIDs: agents
                    ) {
                        callbacks += 1
                        return Data()
                    }
                    throw CheckFailure.expectedRejection
                } catch PluginsFixturePolicyError.invalid {}
                precondition(callbacks == 0)
            }
            var delegated = 0
            let closed = try PluginsFixturePolicy(
                validateSurface: { operation, body in
                    precondition(operation == command && body == Data("{}".utf8))
                    delegated += 1
                    throw PluginsFixturePolicyError.invalid
                }, requireCurrent: {})
            do {
                _ = try await closed.perform(
                    command, payload: Data("{}".utf8), skillIDs: skills, agentIDs: agents
                ) {
                    throw CheckFailure.unexpectedCallback
                }
                throw CheckFailure.expectedRejection
            } catch PluginsFixturePolicyError.invalid {}
            precondition(delegated == 1)
        }
        var current = true
        var validations = 0
        var executions = 0
        let policy = try PluginsFixturePolicy {
            validations += 1
            guard current else { throw PluginsFixturePolicyError.unavailable }
        }
        let payload = Data(allowed[0].utf8)
        let response = Data("synthetic-policy-response".utf8)
        let result = try await policy.perform(
            "plugins.ui.action", payload: payload, skillIDs: skills, agentIDs: agents
        ) {
            executions += 1
            await Task.yield()
            return response
        }
        precondition(result == response && validations == 3 && executions == 1)
        for value in denied {
            let before = executions
            do {
                _ = try await policy.perform(
                    "plugins.ui.action", payload: Data(value.utf8),
                    skillIDs: skills, agentIDs: agents
                ) {
                    executions += 1
                    return response
                }
                throw CheckFailure.expectedRejection
            } catch PluginsFixturePolicyError.invalid {}
            precondition(executions == before)
        }
        for command in ["plugins.ui.document", "plugins.ui.copy", "plugins.cli", "tool.execute"] {
            let before = executions
            do {
                _ = try await policy.perform(
                    command, payload: payload, skillIDs: skills, agentIDs: agents
                ) {
                    executions += 1
                    return response
                }
                throw CheckFailure.expectedRejection
            } catch PluginsFixturePolicyError.invalid {}
            precondition(executions == before)
        }
        let cancelled = Task { @MainActor in
            try await policy.perform(
                "plugins.ui.action", payload: payload, skillIDs: skills, agentIDs: agents
            ) {
                executions += 1
                return response
            }
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw CheckFailure.expectedRejection
        } catch is CancellationError {}
        precondition(executions == 1)
        let cancelledDuringAction = Task { @MainActor in
            try await policy.perform(
                "plugins.ui.action", payload: payload, skillIDs: skills, agentIDs: agents
            ) {
                withUnsafeCurrentTask { $0?.cancel() }
                await Task.yield()
                return response
            }
        }
        do {
            _ = try await cancelledDuringAction.value
            throw CheckFailure.expectedRejection
        } catch is CancellationError {}
        current = false
        do {
            _ = try await policy.perform(
                "plugins.ui.action", payload: payload, skillIDs: skills, agentIDs: agents
            ) {
                executions += 1; return response
            }
            throw CheckFailure.expectedRejection
        } catch PluginsFixturePolicyError.unavailable {}
        precondition(executions == 1)
        current = true
        do {
            _ = try await policy.perform(
                "plugins.ui.action", payload: payload, skillIDs: skills, agentIDs: agents
            ) {
                await Task.yield()
                current = false
                return response
            }
            throw CheckFailure.expectedRejection
        } catch PluginsFixturePolicyError.unavailable {}
        current = true
        do {
            _ = try await policy.perform(
                "plugins.ui.action", payload: payload, skillIDs: skills, agentIDs: agents
            ) {
                policy.stop()
                await Task.yield()
                return response
            }
            throw CheckFailure.expectedRejection
        } catch PluginsFixturePolicyError.unavailable {}
    }

    private enum CheckFailure: Error { case expectedRejection, unexpectedCallback }
    private static func rejects(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw CheckFailure.expectedRejection
    }
}

#if FUNCTIONAL_FIXTURE_CHECKS
@main struct PluginsFixturePolicyRunner {
    static func main() async throws {
        try await PluginsFixturePolicyChecks.run()
        print("plugins synthetic policy checks passed")
    }
}
#else
@Suite struct PluginsFixturePolicyTests {
    @MainActor @Test func strictPayloadsAndCurrentness() async throws {
        try await PluginsFixturePolicyChecks.run()
    }
}
#endif
