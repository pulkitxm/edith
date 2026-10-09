import EdithExtensionSupport
import Foundation

public enum CodeStatsExecutionEnvironment {
    public static var fixtureHome: URL? {
        guard let path = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"],
            path.hasPrefix("/"), !path.utf8.contains(0)
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    public static var home: URL { fixtureHome ?? FileManager.default.homeDirectoryForCurrentUser }
    public static func git() async -> CodeStatsGit? {
        guard let fixtureHome else {
            return await CodeStatsGit.resolve(
                credentialHelper: CLIToolEnvironment.executable(named: "gh"))
        }
        var environment = CLIToolEnvironment.sanitized()
        environment["HOME"] = fixtureHome.path
        environment["XDG_CONFIG_HOME"] = fixtureHome.appendingPathComponent(".config").path
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "SSH_AUTH_SOCK", "GIT_SSH_COMMAND", "GIT_SSH"] {
            environment.removeValue(forKey: key)
        }
        return await CodeStatsGit.resolve(
            candidate: CLIToolEnvironment.executable(named: "git"),
            environment: environment,
            developerDirectory: { await CodeStatsGit.activeDeveloperDirectory() })
    }
}
