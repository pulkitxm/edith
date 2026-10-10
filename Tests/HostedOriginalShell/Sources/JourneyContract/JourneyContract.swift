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
    public let executableSHA256: [String: String]
    public let versions: [String]
    public let appVersions: [String]
    public let protectedSHA256: [String: String]

    public var application: String { directory + "/Host.app" }
    public var executable: String { application + "/Contents/MacOS/Edith" }
    public var home: String { directory + "/synthetic-data" }
    public var support: String { directory + "/support" }
    public var defaultsSuite: String { identifier }
    public var sessionDefaultsSuite: String { identifier + ".host" }
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
        executableSHA256: [String: String], versions: [String], appVersions: [String],
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
        guard schema == 1, hex(sourceCommit, length: 40),
            Set(executableSHA256.keys) == Set(appVersions),
            executableSHA256.values.allSatisfy({ hex($0, length: 64) }),
            versions == ["1.0.0", "1.1.0"], appVersions == ["1.0.0", "2.0.0"],
            Set(protectedSHA256.keys) == protectedRelativePaths,
            protectedSHA256.values.allSatisfy({ hex($0, length: 64) })
        else { throw JourneyContractError.invalidMetadata }
    }

    public func applicationEnvironment(from runnerEnvironment: [String: String]) throws -> [String:
        String]
    {
        guard let accountHome = runnerEnvironment["EDITH_JOURNEY_ACCOUNT_HOME"] else {
            throw JourneyContractError.invalidEnvironment
        }
        try validate(accountHome: accountHome, environment: runnerEnvironment)
        guard runnerEnvironment["EDITH_APPLICATION_IDENTIFIER"] == identifier,
            runnerEnvironment["EDITH_SHARED_DEFAULTS_SUITE"] == defaultsSuite,
            runnerEnvironment["EDITH_EXTENSION_FIXTURE_HOME"] == home,
            runnerEnvironment["EDITH_GUI_FIXTURE_DIRECTORY"] == directory
        else { throw JourneyContractError.invalidEnvironment }
        let result = [
            "GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS",
            "RUNNER_ENVIRONMENT": "github-hosted", "EDITH_HOSTED_SHELL_JOURNEY": "1",
            "HOME": home, "XDG_CONFIG_HOME": home + "/.config",
            "XDG_CACHE_HOME": home + "/.cache", "XDG_DATA_HOME": home + "/.local/share",
            "EDITH_APPLICATION_IDENTIFIER": identifier,
            "EDITH_SHARED_DEFAULTS_SUITE": defaultsSuite,
            "EDITH_EXTENSION_FIXTURE_HOME": home, "EDITH_GUI_FIXTURE_DIRECTORY": directory,
        ]
        try validateApplicationEnvironment(result)
        return result
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

public struct JourneyProcessObservation: Codable, Equatable, Sendable {
    public let role: String
    public let pid: Int32
    public let generation: String
    public let running: Bool
    public let residentBytes: UInt64?

    public init(role: String, pid: Int32, generation: String, running: Bool, residentBytes: UInt64?)
    {
        self.role = role
        self.pid = pid
        self.generation = generation
        self.running = running
        self.residentBytes = running ? residentBytes : nil
    }
}

public struct JourneyProcessRegistry: Sendable {
    public struct Identity: Equatable, Sendable {
        public let pid: Int32
        public let generation: String
        public let executable: String

        public init(pid: Int32, generation: String, executable: String) {
            self.pid = pid
            self.generation = generation
            self.executable = executable
        }
    }

    private var owned: [String: Identity] = [:]

    public init() {}

    public mutating func register(role: String, identity: Identity, expectedExecutable: String)
        throws
    {
        guard ["host", "engine", "managedUI"].contains(role), identity.pid > 1,
            !identity.generation.isEmpty, identity.generation.utf8.count <= 64,
            identity.executable == expectedExecutable, expectedExecutable.hasPrefix("/"),
            owned.count < 64 || owned.values.contains(identity)
        else { throw JourneyContractError.invalidMetadata }
        owned[role + ":" + String(identity.pid) + ":" + identity.generation] = identity
    }

    public func observations(
        identity: (Int32) -> Identity?, residentBytes: (Int32) -> UInt64?
    ) -> [JourneyProcessObservation] {
        owned.keys.sorted().compactMap { key in
            guard let expected = owned[key], let role = key.split(separator: ":").first else {
                return nil
            }
            let running = identity(expected.pid) == expected
            let bytes = running ? residentBytes(expected.pid) : nil
            let stillRunning = running && identity(expected.pid) == expected
            return JourneyProcessObservation(
                role: String(role), pid: expected.pid, generation: expected.generation,
                running: stillRunning, residentBytes: stillRunning ? bytes : nil)
        }
    }
}
