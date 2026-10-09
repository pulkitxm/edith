import Foundation

public protocol JevDeciding: Sendable {
    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision
}

public enum JevAvailability {
    private static let configuredKey = "docsJevConfigured"

    public static func isConfigured(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: configuredKey)
    }

    public static func record(configured: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(configured, forKey: configuredKey)
    }
}
