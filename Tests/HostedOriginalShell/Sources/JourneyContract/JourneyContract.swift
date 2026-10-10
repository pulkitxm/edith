import Foundation

public enum JourneyContractError: Error, Equatable {
    case untrustedRunner
    case invalidIdentity
    case invalidPaths
    case invalidMetadata
    case invalidEnvironment
    case protectedDataChanged
}

public struct JourneyFixture: Codable, Equatable, Sendable {
    public let schema: Int
    public let identifier: String
    public let directory: String
    public let sourceCommit: String
    public let executableSHA256: String
    public let versions: [String]
    public let appVersions: [String]
    public let protectedSHA256: [String: String]

    public var application: String { directory + "/Host.app" }
    public var executable: String { application + "/Contents/MacOS/Edith" }
    public var home: String { directory + "/synthetic-data" }
    public var support: String { directory + "/support" }
    public var defaultsSuite: String { identifier + ".host" }
    public var identityRoot: String {
        support + "/Edith Tests/" + identifier.dropFirst("com.pulkit.edith.tests.".count)
    }
    public var protectedRelativePaths: Set<String> {
        [
            "production-sentinel/usage.json",
            "support/Edith Tests/"
                + identifier.dropFirst("com.pulkit.edith.tests.".count)
                + "/Data/calendar/retained-fixture.json",
        ]
    }

    public init(
        schema: Int = 1, identifier: String, directory: String, sourceCommit: String,
        executableSHA256: String, versions: [String], appVersions: [String],
        protectedSHA256: [String: String]
    ) {
        self.schema = schema
        self.identifier = identifier
        self.directory = directory
        self.sourceCommit = sourceCommit
        self.executableSHA256 = executableSHA256
        self.versions = versions
        self.appVersions = appVersions
        self.protectedSHA256 = protectedSHA256
    }

    public func validate(accountHome: String, environment: [String: String]) throws {
        guard environment["GITHUB_ACTIONS"] == "true",
            environment["RUNNER_OS"] == "macOS",
            environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            environment["EDITH_HOSTED_SHELL_JOURNEY"] == "1"
        else { throw JourneyContractError.untrustedRunner }
        let prefix = "com.pulkit.edith.tests.remote-"
        let suffix = String(identifier.dropFirst(prefix.count))
        guard identifier.hasPrefix(prefix),
            UUID(uuidString: suffix)?.uuidString.lowercased() == suffix
        else { throw JourneyContractError.invalidIdentity }
        guard directory == accountHome + "/Applications/Edith Remote Fixture Journey " + suffix,
            canonical(directory), canonical(accountHome)
        else { throw JourneyContractError.invalidPaths }
        guard schema == 1, hex(sourceCommit, length: 40), hex(executableSHA256, length: 64),
            versions == ["1.0.0", "1.1.0"], appVersions == ["1.0.0", "2.0.0"],
            Set(protectedSHA256.keys) == protectedRelativePaths,
            protectedSHA256.values.allSatisfy({ hex($0, length: 64) })
        else { throw JourneyContractError.invalidMetadata }
    }

    public func validateApplicationEnvironment(_ environment: [String: String]) throws {
        guard environment["HOME"] == home,
            environment["XDG_CONFIG_HOME"] == home + "/.config",
            environment["XDG_CACHE_HOME"] == home + "/.cache",
            environment["XDG_DATA_HOME"] == home + "/.local/share",
            environment["EDITH_APPLICATION_IDENTIFIER"] == identifier,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == defaultsSuite,
            environment["EDITH_EXTENSION_FIXTURE_HOME"] == home,
            environment["EDITH_GUI_FIXTURE_DIRECTORY"] == directory,
            environment["SSH_AUTH_SOCK"] == nil
        else { throw JourneyContractError.invalidEnvironment }
    }

    public func verifyProtectedDigests(_ actual: [String: String]) throws {
        guard actual == protectedSHA256 else { throw JourneyContractError.protectedDataChanged }
    }

    private func canonical(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096 && !value.contains("\0")
            && !value.contains("\n") && !value.contains("\r")
            && URL(fileURLWithPath: value).standardizedFileURL.path == value
    }

    private func hex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
