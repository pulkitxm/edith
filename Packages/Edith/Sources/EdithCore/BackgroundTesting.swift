import Foundation

public enum BackgroundTesting {
    public static let environmentKey = "EDITH_BACKGROUND_TESTING"
    public static let launchArgument = "--edith-background-testing"

    public static func isHonored(
        environmentValue: String?,
        arguments: [String] = [],
        applicationIdentifier: String
    ) -> Bool {
        let requested =
            environmentValue == "1" || arguments.contains(launchArgument)
        guard requested else { return false }
        return applicationIdentifier != AppBuildIdentity.production
            && applicationIdentifier.hasPrefix(AppBuildIdentity.production + ".")
    }

    public static var isActive: Bool {
        isHonored(
            environmentValue: ProcessInfo.processInfo.environment[environmentKey],
            arguments: ProcessInfo.processInfo.arguments,
            applicationIdentifier: AppBuildIdentity.application)
    }
}
