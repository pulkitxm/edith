import Foundation

enum BackgroundTesting {
    static let environmentKey = "EDITH_BACKGROUND_TESTING"
    static let launchArgument = "--edith-background-testing"
    static let production = "com.pulkit.edith"

    static func isHonored(
        environmentValue: String?, arguments: [String] = [], applicationIdentifier: String
    ) -> Bool {
        guard environmentValue == "1" || arguments.contains(launchArgument) else { return false }
        return applicationIdentifier != production
            && applicationIdentifier.hasPrefix(production + ".")
    }

    static var isActive: Bool {
        isHonored(
            environmentValue: ProcessInfo.processInfo.environment[environmentKey],
            arguments: ProcessInfo.processInfo.arguments,
            applicationIdentifier: Bundle.main.bundleIdentifier ?? "")
    }
}
