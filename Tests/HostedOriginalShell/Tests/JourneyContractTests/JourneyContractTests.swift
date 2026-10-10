import Foundation
import JourneyContract
import Testing

private let uuid = "00000000-0000-4000-8000-000000000001"
private let identifier = "com.pulkit.edith.tests.remote-" + uuid
private let directory = "/Users/fixture/Applications/Edith Remote Fixture Journey " + uuid
private let runner = [
    "GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS", "RUNNER_ENVIRONMENT": "github-hosted",
    "EDITH_HOSTED_SHELL_JOURNEY": "1",
]

private func fixture(identifier: String = identifier, directory: String = directory)
    -> JourneyFixture
{
    let relative =
        "support/Edith Tests/"
        + identifier.dropFirst("com.pulkit.edith.tests.".count)
        + "/Data/calendar/retained-fixture.json"
    return JourneyFixture(
        identifier: identifier, directory: directory,
        sourceCommit: String(repeating: "a", count: 40),
        executableSHA256: [
            "1.0.0": String(repeating: "b", count: 64),
            "2.0.0": String(repeating: "e", count: 64),
        ], versions: ["1.0.0", "1.1.0"],
        appVersions: ["1.0.0", "2.0.0"],
        protectedSHA256: [
            "production-sentinel/usage.json": String(repeating: "c", count: 64),
            relative: String(repeating: "d", count: 64),
        ])
}

@Test func exactDisposableRunnerAndOwnedNamespaceAreRequired() throws {
    try fixture().validate(accountHome: "/Users/fixture", environment: runner)
    for key in runner.keys {
        var changed = runner
        changed[key] = "invalid"
        #expect(throws: JourneyContractError.untrustedRunner) {
            try fixture().validate(accountHome: "/Users/fixture", environment: changed)
        }
    }
    #expect(throws: JourneyContractError.invalidIdentity) {
        try fixture(identifier: "com.pulkit.edith").validate(
            accountHome: "/Users/fixture", environment: runner)
    }
    #expect(throws: JourneyContractError.invalidPaths) {
        try fixture(directory: directory + "/../other").validate(
            accountHome: "/Users/fixture", environment: runner)
    }
}

@Test func applicationEnvironmentCannotUseAmbientHomeDefaultsOrSSH() throws {
    let fixture = fixture()
    let environment = [
        "HOME": fixture.home, "XDG_CONFIG_HOME": fixture.home + "/.config",
        "XDG_CACHE_HOME": fixture.home + "/.cache", "XDG_DATA_HOME": fixture.home + "/.local/share",
        "EDITH_APPLICATION_IDENTIFIER": identifier,
        "EDITH_SHARED_DEFAULTS_SUITE": fixture.defaultsSuite,
        "EDITH_EXTENSION_FIXTURE_HOME": fixture.home, "EDITH_GUI_FIXTURE_DIRECTORY": directory,
    ]
    try fixture.validateApplicationEnvironment(environment)
    for key in environment.keys {
        var changed = environment
        changed[key] = "/Users/actual"
        #expect(throws: JourneyContractError.invalidEnvironment) {
            try fixture.validateApplicationEnvironment(changed)
        }
    }
    #expect(throws: JourneyContractError.invalidEnvironment) {
        try fixture.validateApplicationEnvironment(
            environment.merging(["SSH_AUTH_SOCK": "/tmp/socket"]) { _, next in next })
    }
}

@Test func protectedProductionSentinelAndRetainedDataMustRemainByteIdentical() throws {
    let fixture = fixture()
    try fixture.verifyProtectedDigests(fixture.protectedSHA256)
    for path in fixture.protectedSHA256.keys {
        var actual = fixture.protectedSHA256
        actual[path] = String(repeating: "0", count: 64)
        #expect(throws: JourneyContractError.protectedDataChanged) {
            try fixture.verifyProtectedDigests(actual)
        }
        actual.removeValue(forKey: path)
        #expect(throws: JourneyContractError.protectedDataChanged) {
            try fixture.verifyProtectedDigests(actual)
        }
    }
}

@Test func ownedProcessMetricsRejectPIDReuseAndNeverReadForeignPID() throws {
    var registry = JourneyProcessRegistry()
    let host = JourneyProcessRegistry.Identity(
        pid: 44, generation: "1:2", executable: "/fixture/Host.app/Edith")
    try registry.register(role: "host", identity: host, expectedExecutable: host.executable)
    var reads: [Int32] = []
    let live = registry.observations(
        identity: { _ in host },
        residentBytes: {
            reads.append($0); return 4_096
        })
    #expect(live.first?.residentBytes == 4_096)
    #expect(reads == [44])
    reads = []
    let replaced = registry.observations(
        identity: { pid in .init(pid: pid, generation: "3:4", executable: host.executable) },
        residentBytes: {
            reads.append($0); return 8_192
        })
    #expect(replaced.first?.running == false)
    #expect(replaced.first?.residentBytes == nil)
    #expect(reads.isEmpty)
    #expect(throws: JourneyContractError.invalidMetadata) {
        try registry.register(role: "engine", identity: host, expectedExecutable: "/foreign/Edith")
    }
}

@Test func processExitDuringMeasurementDoesNotBecomeZeroMemory() throws {
    var registry = JourneyProcessRegistry()
    let process = JourneyProcessRegistry.Identity(
        pid: 55, generation: "5:6", executable: "/fixture/Worker")
    try registry.register(
        role: "managedUI", identity: process, expectedExecutable: process.executable)
    var queries = 0
    let observations = registry.observations(
        identity: { _ in
            queries += 1
            return queries == 1 ? process : nil
        }, residentBytes: { _ in 16_384 })
    #expect(observations.first?.running == false)
    #expect(observations.first?.residentBytes == nil)
}

@Test func runnerHomeAndAmbientCredentialsNeverBecomeApplicationEnvironment() throws {
    let value = fixture()
    let environment = runner.merging([
        "EDITH_JOURNEY_ACCOUNT_HOME": "/Users/fixture",
        "EDITH_APPLICATION_IDENTIFIER": identifier,
        "EDITH_SHARED_DEFAULTS_SUITE": value.defaultsSuite,
        "EDITH_EXTENSION_FIXTURE_HOME": value.home,
        "EDITH_GUI_FIXTURE_DIRECTORY": directory,
        "HOME": "/Users/fixture/Library/Developer/XCTestDevices/runner",
        "XDG_CONFIG_HOME": "/ambient/config", "SSH_AUTH_SOCK": "/ambient/socket",
        "PRIVATE_TOKEN": "synthetic-secret",
    ]) { _, next in next }
    let application = try value.applicationEnvironment(from: environment)
    try value.validateApplicationEnvironment(application)
    #expect(application["HOME"] == value.home)
    #expect(application["XDG_CONFIG_HOME"] == value.home + "/.config")
    #expect(application["SSH_AUTH_SOCK"] == nil)
    #expect(application["PRIVATE_TOKEN"] == nil)
    for key in [
        "EDITH_JOURNEY_ACCOUNT_HOME", "EDITH_APPLICATION_IDENTIFIER",
        "EDITH_SHARED_DEFAULTS_SUITE", "EDITH_EXTENSION_FIXTURE_HOME",
        "EDITH_GUI_FIXTURE_DIRECTORY", "EDITH_HOSTED_SHELL_JOURNEY",
    ] {
        var changed = environment
        changed[key] = "invalid"
        #expect(throws: (any Error).self) {
            try value.applicationEnvironment(from: changed)
        }
    }
}
