import Foundation
import Testing
import WorkerLifecycleFixtureSupport
@testable import HostLifecycleHarness

@Suite struct UsageFixtureHomeTests {
    private struct Fixture {
        let root: URL
        let issuer: WorkerLifecycleFixture
        let home: URL
        let environment: [String: String]

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("usage-home-contract-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            issuer = try WorkerLifecycleFixture(
                root: root, hostIdentifier: "com.pulkit.edith.tests.worker-" + UUID().uuidString)
            home = try issuer.home(for: "usage")
            environment = [
                "HOME": home.path, "CFFIXED_USER_HOME": home.path,
                "EDITH_EXTENSION_FIXTURE_HOME": home.path,
            ]
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func ownedFixtureHomeMayBeTheClosedProcessHome() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(
            try HostLifecycleHarness.usageFixtureHome(
                fixture.issuer, environment: fixture.environment) == fixture.home)
    }

    @Test(arguments: [
        "missing-fixture", "missing-home", "missing-fixed-home", "foreign-fixture",
        "foreign-home", "foreign-fixed-home", "different-owner", "relative", "noncanonical",
        "home-permission", "root-permission", "home-symlink",
    ])
    func untrustedFixtureHomesAreRejected(_ mutation: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var environment = fixture.environment
        switch mutation {
        case "missing-fixture": environment["EDITH_EXTENSION_FIXTURE_HOME"] = nil
        case "missing-home": environment["HOME"] = nil
        case "missing-fixed-home": environment["CFFIXED_USER_HOME"] = nil
        case "foreign-fixture": environment["EDITH_EXTENSION_FIXTURE_HOME"] = "/synthetic/foreign"
        case "foreign-home": environment["HOME"] = "/synthetic/foreign"
        case "foreign-fixed-home": environment["CFFIXED_USER_HOME"] = "/synthetic/foreign"
        case "different-owner":
            environment["EDITH_EXTENSION_FIXTURE_HOME"] =
                fixture.root.appendingPathComponent("machines-home").path
        case "relative": environment["EDITH_EXTENSION_FIXTURE_HOME"] = "usage-home"
        case "noncanonical":
            environment["EDITH_EXTENSION_FIXTURE_HOME"] =
                fixture.root.path + "/usage-home/../usage-home"
        case "home-permission":
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fixture.home.path)
        case "root-permission":
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
        case "home-symlink":
            let original = fixture.root.appendingPathComponent("original-home")
            try FileManager.default.moveItem(at: fixture.home, to: original)
            try FileManager.default.createSymbolicLink(
                at: fixture.home, withDestinationURL: original)
        default: Issue.record("Unknown fixture mutation")
        }
        #expect(throws: (any Error).self) {
            try HostLifecycleHarness.usageFixtureHome(fixture.issuer, environment: environment)
        }
    }

    @Test func aBroadEnvironmentHintWithoutAnOwnedIssuerIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: (any Error).self) {
            try HostLifecycleHarness.usageFixtureHome(nil, environment: fixture.environment)
        }
    }
}
