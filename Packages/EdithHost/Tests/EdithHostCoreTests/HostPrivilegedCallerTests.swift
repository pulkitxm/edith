import Darwin
import ExtensionMarketplace
import Foundation
import Security
import Testing
@testable import EdithHostCore

@Suite struct HostPrivilegedCallerTests {
    private let host = "com.pulkit.edith.tests.contained"
    private let owner = "sample"
    private let version = "1.0.0"
    private let root = URL(fileURLWithPath: "/Library/Application Support/Synthetic/Carrier.app")

    @Test func signedContainedMetadataBindsOwnerVersionAndExactNestedPayload() throws {
        let caller = try fixture()
        #expect(caller.container?.path == root.path)
        try caller.authorize(source: payload, owner: owner, version: version)
        for source in [
            root.appendingPathComponent("Contents/Other/privileged.bundle"),
            URL(fileURLWithPath: payload.path + "/../privileged.bundle"),
            URL(fileURLWithPath: "/synthetic/privileged.bundle"),
        ] {
            #expect(throws: MarketplaceError.self) {
                try caller.authorize(source: source, owner: owner, version: version)
            }
        }
        #expect(throws: MarketplaceError.self) {
            try caller.authorize(source: payload, owner: "other", version: version)
        }
        #expect(throws: MarketplaceError.self) {
            try caller.authorize(source: payload, owner: owner, version: "2.0.0")
        }
    }

    @Test(arguments: [
        "EdithContainedRole", "EdithContainedExtensionID", "EdithHostIdentifier", "EdithHostABI",
        "EdithExecutableProvenance", "CFBundleIdentifier", "CFBundleShortVersionString",
    ])
    func missingOrEmptySignedMetadataIsRejected(key: String) {
        #expect(throws: MarketplaceError.self) { try fixture(remove: key) }
        #expect(throws: MarketplaceError.self) { try fixture(replace: [key: ""]) }
    }

    @Test func ordinaryHostIdentityRemainsSeparateFromContainedIdentity() throws {
        let caller = try HostPrivilegedCaller(
            information: [
                kSecCodeInfoIdentifier as String: host,
                kSecCodeInfoPList as String: ["CFBundleIdentifier": host],
            ], hostIdentifier: host, hostABI: HostContract.compatibility)
        #expect(caller.container == nil)
        try caller.authorize(source: payload, owner: owner, version: version)
        #expect(throws: MarketplaceError.self) {
            try caller.authorize(
                source: URL(string: "https://example.invalid/payload")!,
                owner: owner, version: version)
        }
    }

    @Test func connectionRequirementCompilesAndRejectsInjectedValues() throws {
        let expression = try HostPrivilegedCaller.requirement(
            hostIdentifier: host, team: "SYNTHETIC1")
        var requirement: SecRequirement?
        #expect(
            SecRequirementCreateWithString(expression as CFString, [], &requirement)
                == errSecSuccess)
        #expect(requirement != nil)
        #expect(throws: MarketplaceError.self) {
            try HostPrivilegedCaller.requirement(hostIdentifier: host + "\" or true", team: "TEAM")
        }
        #expect(throws: MarketplaceError.self) {
            try HostPrivilegedCaller.read(processIdentifier: 0, hostIdentifier: host, team: "TEAM")
        }
    }

    @Test func providerRolesAndUnsealedExecutableLayoutsNeverQualifyAsCarriers() {
        #expect(throws: MarketplaceError.self) {
            try fixture(replace: ["EdithContainedRole": "sampleProvider"])
        }
        #expect(throws: MarketplaceError.self) {
            try fixture(executable: root.appendingPathComponent("Runtime"))
        }
        #expect(throws: MarketplaceError.self) {
            try fixture(
                executable: URL(fileURLWithPath: "/synthetic.bundle/Contents/MacOS/Runtime"))
        }
    }

    @Test func writablePlatformParentRequiresARootProtectedNonRenamableAnchor() throws {
        var platform = stat()
        platform.st_uid = 0; platform.st_gid = 80; platform.st_mode = S_IFDIR | 0o775
        var anchor = stat()
        anchor.st_uid = 0; anchor.st_mode = S_IFDIR | 0o755; anchor.st_flags = UInt32(SF_NOUNLINK)
        let applications = URL(fileURLWithPath: "/Applications")
        try HostPrivilegedCaller.validateAncestor(
            applications, metadata: platform, protectedChild: anchor)
        #expect(throws: MarketplaceError.self) {
            try HostPrivilegedCaller.validateAncestor(
                applications, metadata: platform, protectedChild: nil)
        }
        #expect(throws: MarketplaceError.self) {
            try HostPrivilegedCaller.validateAncestor(
                URL(fileURLWithPath: "/synthetic"), metadata: platform, protectedChild: anchor)
        }
        anchor.st_flags = 0
        #expect(throws: MarketplaceError.self) {
            try HostPrivilegedCaller.validateAncestor(
                applications, metadata: platform, protectedChild: anchor)
        }
        anchor.st_flags = UInt32(SF_NOUNLINK); anchor.st_uid = 501
        #expect(throws: MarketplaceError.self) {
            try HostPrivilegedCaller.validateAncestor(
                applications, metadata: platform, protectedChild: anchor)
        }
        anchor.st_uid = 0; anchor.st_mode = S_IFDIR | 0o775
        #expect(throws: MarketplaceError.self) {
            try HostPrivilegedCaller.validateAncestor(
                applications, metadata: platform, protectedChild: anchor)
        }
        anchor.st_mode = S_IFDIR | 0o755; platform.st_mode = S_IFDIR | 0o777
        #expect(throws: MarketplaceError.self) {
            try HostPrivilegedCaller.validateAncestor(
                applications, metadata: platform, protectedChild: anchor)
        }
        platform.st_mode = S_IFLNK | 0o755
        #expect(throws: MarketplaceError.self) {
            try HostPrivilegedCaller.validateAncestor(
                applications, metadata: platform, protectedChild: anchor)
        }
    }

    private var payload: URL { root.appendingPathComponent("Contents/PlugIns/privileged.bundle") }

    private func fixture(
        remove: String? = nil, replace: [String: String] = [:], executable: URL? = nil
    )
        throws -> HostPrivilegedCaller
    {
        var info: [String: Any] = [
            "CFBundleIdentifier": host + ".sampleCarrier",
            "CFBundleShortVersionString": version,
            "EdithContainedRole": "sampleCarrier", "EdithContainedExtensionID": owner,
            "EdithHostIdentifier": host, "EdithHostABI": HostContract.compatibility,
            "EdithExecutableProvenance": String(repeating: "a", count: 64),
        ]
        if let remove { info[remove] = nil }
        for (key, value) in replace { info[key] = value }
        return try HostPrivilegedCaller(
            information: [
                kSecCodeInfoIdentifier as String: host + ".sampleCarrier",
                kSecCodeInfoPList as String: info,
                kSecCodeInfoMainExecutable as String: executable
                    ?? root.appendingPathComponent("Contents/MacOS/Runtime"),
            ], hostIdentifier: host, hostABI: HostContract.compatibility)
    }
}
