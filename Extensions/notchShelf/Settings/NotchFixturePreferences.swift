import Foundation

enum NotchFixturePreferencesError: Error { case invalid, unavailable }

@MainActor final class NotchFixturePreferences {
    private let defaults: UserDefaults
    private let schema: [String: String]
    private let isString: (String) -> Bool
    private let accepts: (String, String) -> Bool
    private let requireCurrent: () throws -> Void
    private var stopped = false

    init(
        suite: String, expectedSuite: String, schema: [String: String],
        isString: @escaping (String) -> Bool, accepts: @escaping (String, String) -> Bool,
        requireCurrent: @escaping () throws -> Void,
        makeDefaults: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) throws {
        try requireCurrent()
        let prefix = "com.pulkit.edith.tests.worker-"
        let suffix = ".extensions.notchShelf"
        guard suite == expectedSuite, suite.hasPrefix(prefix), suite.hasSuffix(suffix),
            UUID(uuidString: String(suite.dropFirst(prefix.count).dropLast(suffix.count))) != nil,
            !schema.isEmpty, schema.allSatisfy({ accepts($0.key, $0.value) }),
            let defaults = makeDefaults(suite)
        else { throw NotchFixturePreferencesError.invalid }
        self.defaults = defaults
        self.schema = schema
        self.isString = isString
        self.accepts = accepts
        self.requireCurrent = requireCurrent
        try requireCurrent()
    }

    func stop() { stopped = true }

    func execute(_ command: String, payload: Data) throws -> [String: String] {
        try current()
        guard payload.count <= 4096,
            let fields = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw NotchFixturePreferencesError.invalid }
        switch command {
        case "notch.settings.read":
            guard fields.isEmpty else { throw NotchFixturePreferencesError.invalid }
        case "notch.settings.write":
            guard Set(fields.keys) == ["key", "value"],
                let key = fields["key"] as? String, let value = fields["value"] as? String,
                schema[key] != nil, accepts(key, value)
            else { throw NotchFixturePreferencesError.invalid }
            try current()
            if isString(key) {
                defaults.set(value, forKey: key)
            } else {
                defaults.set(value == "1", forKey: key)
            }
        default: throw NotchFixturePreferencesError.invalid
        }
        var preferences = schema
        for (key, fallback) in schema {
            if isString(key) {
                let value = defaults.string(forKey: key) ?? fallback
                preferences[key] = accepts(key, value) ? value : fallback
            } else {
                preferences[key] =
                    (defaults.object(forKey: key) as? Bool ?? (fallback == "1")) ? "1" : "0"
            }
        }
        try current()
        return preferences
    }

    private func current() throws {
        guard !stopped else { throw NotchFixturePreferencesError.unavailable }
        try Task.checkCancellation()
        try requireCurrent()
    }
}
