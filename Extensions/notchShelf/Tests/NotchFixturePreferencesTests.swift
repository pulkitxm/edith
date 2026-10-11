import Foundation
#if !FUNCTIONAL_FIXTURE_CHECKS
import Testing
@testable import NotchShelfExtension
#endif

@MainActor enum NotchFixturePreferencesChecks {
    static func run() throws {
        let suite = "com.pulkit.edith.tests.worker-" + UUID().uuidString + ".extensions.notchShelf"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailure.defaults }
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = ["synthetic.boolean": "1", "synthetic.string": "forever"]
        let accepts: (String, String) -> Bool = { key, value in
            if key == "synthetic.boolean" { return value == "0" || value == "1" }
            return key == "synthetic.string" && ["forever", "oneHour"].contains(value)
        }
        var current = true
        var validations = 0
        let backend = try NotchFixturePreferences(
            suite: suite, expectedSuite: suite, schema: schema,
            isString: { $0 == "synthetic.string" }, accepts: accepts,
            requireCurrent: {
                validations += 1
                guard current else { throw NotchFixturePreferencesError.unavailable }
            })
        let initial = try backend.execute("notch.settings.read", payload: Data("{}".utf8))
        precondition(initial == schema)
        let boolean = Data("{\"key\":\"synthetic.boolean\",\"value\":\"0\"}".utf8)
        let string = Data("{\"key\":\"synthetic.string\",\"value\":\"oneHour\"}".utf8)
        _ = try backend.execute("notch.settings.write", payload: boolean)
        _ = try backend.execute("notch.settings.write", payload: string)
        precondition(defaults.object(forKey: "synthetic.boolean") as? Bool == false)
        precondition(defaults.string(forKey: "synthetic.string") == "oneHour")
        let reopened = try NotchFixturePreferences(
            suite: suite, expectedSuite: suite, schema: schema,
            isString: { $0 == "synthetic.string" }, accepts: accepts, requireCurrent: {})
        let persisted = try reopened.execute("notch.settings.read", payload: Data("{}".utf8))
        precondition(persisted == ["synthetic.boolean": "0", "synthetic.string": "oneHour"])
        for value in [
            "{}", "[]", "null", "{", "{\"key\":\"unowned\",\"value\":\"1\"}",
            "{\"key\":\"synthetic.boolean\",\"value\":true}",
            "{\"key\":\"synthetic.boolean\",\"value\":1}",
            "{\"key\":\"synthetic.boolean\",\"value\":null}",
            "{\"key\":\"synthetic.boolean\",\"value\":\"yes\"}",
            "{\"key\":\"synthetic.string\",\"value\":\"unowned\"}",
            "{\"key\":\"synthetic.string\",\"value\":\"forever\",\"extra\":1}",
            String(repeating: " ", count: 4097),
        ] {
            try rejects {
                _ = try backend.execute("notch.settings.write", payload: Data(value.utf8))
            }
        }
        for value in ["[]", "null", "{\"extra\":true}", String(repeating: " ", count: 4097)] {
            try rejects {
                _ = try backend.execute("notch.settings.read", payload: Data(value.utf8))
            }
        }
        for command in [
            "notch.customize", "notch.browser.detach", "notch.bluetooth.settings",
            "notch.panel.attach", "notch.chrome.camera", "notch.cli", "notchShelf.cli.catalog",
        ] {
            try rejects { _ = try backend.execute(command, payload: Data("{}".utf8)) }
        }
        precondition(defaults.object(forKey: "unowned") == nil)
        for invalidSuite in [
            "production", suite + ".other", suite.replacingOccurrences(of: "worker-", with: "ui-"),
            "com.pulkit.edith.tests.worker-invalid.extensions.notchShelf",
        ] {
            try rejects {
                _ = try NotchFixturePreferences(
                    suite: invalidSuite, expectedSuite: suite, schema: schema,
                    isString: { _ in false }, accepts: accepts, requireCurrent: {},
                    makeDefaults: { _ in throwUnexpectedDefaults() })
            }
        }
        current = false
        try rejects { _ = try backend.execute("notch.settings.write", payload: boolean) }
        try rejects {
            _ = try NotchFixturePreferences(
                suite: suite, expectedSuite: suite, schema: schema,
                isString: { _ in false }, accepts: accepts,
                requireCurrent: { throw NotchFixturePreferencesError.unavailable },
                makeDefaults: { _ in throwUnexpectedDefaults() })
        }
        current = true
        backend.stop()
        try rejects { _ = try backend.execute("notch.settings.read", payload: Data("{}".utf8)) }
        precondition(validations >= 10)
        defaults.set("invalid", forKey: "synthetic.string")
        let repaired = try reopened.execute("notch.settings.read", payload: Data("{}".utf8))
        precondition(repaired["synthetic.string"] == "forever")
    }

    private enum CheckFailure: Error { case defaults, expectedRejection }
    private static func rejects(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw CheckFailure.expectedRejection
    }
    private static func throwUnexpectedDefaults() -> UserDefaults? {
        preconditionFailure("Rejected suite reached defaults construction")
    }
}

#if FUNCTIONAL_FIXTURE_CHECKS
@main struct NotchFixturePreferencesRunner {
    static func main() async throws {
        try NotchFixturePreferencesChecks.run()
        print("notch synthetic preferences checks passed")
    }
}
#else
@Suite struct NotchFixturePreferencesTests {
    @MainActor @Test func strictPayloadsAndPreferencePersistence() throws {
        try NotchFixturePreferencesChecks.run()
    }
}
#endif
