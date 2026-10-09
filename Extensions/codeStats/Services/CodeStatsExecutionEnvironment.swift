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
        let environment = fixtureGitEnvironment(home: fixtureHome)
        let candidate = [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }.map {
            URL(fileURLWithPath: $0)
        }
        return await CodeStatsGit.resolve(
            candidate: candidate, environment: environment, developerDirectory: { nil })
    }

    static func fixtureGitEnvironment(home: URL) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
        ]
    }
}
