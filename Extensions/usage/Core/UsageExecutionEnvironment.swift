import Foundation

public enum UsageExecutionEnvironment {
    public static var fixtureHome: URL? {
        fixtureHome(environment: ProcessInfo.processInfo.environment)
    }

    public static var home: URL {
        fixtureHome ?? FileManager.default.homeDirectoryForCurrentUser
    }

    public static func collectorEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard fixtureHome(environment: environment) != nil else { return environment }
        var isolated = ["EDITH_USAGE_OFFLINE": "1"]
        if let zone = environment["TZ"] { isolated["TZ"] = zone }
        return isolated
    }

    public static func fixtureHome(environment: [String: String]) -> URL? {
        guard let path = environment["EDITH_EXTENSION_FIXTURE_HOME"], path.hasPrefix("/"),
            !path.utf8.contains(0)
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
