import Foundation
import Testing
@testable import VirtualCameraExtension

@Suite struct CameraCarrierEnvironmentTests {
    private let source = URL(
        fileURLWithPath: "/synthetic/extensions/virtualCamera/1.0.0/CameraCarrier.app")
    private let inherited = [
        "PATH": "/usr/bin:/bin", "HOME": "/synthetic/owner-home",
        "EDITH_EXTENSION_FIXTURE_HOME": "/synthetic/owner-home",
        "EDITH_SHARED_DEFAULTS_SUITE": "synthetic.camera.preferences",
        "EDITH_EXTENSION_DATA_ROOT": "/synthetic/support/Data/virtualCamera",
        "DYLD_LIBRARY_PATH": "/synthetic/loader", "DYLD_INSERT_LIBRARIES": "/synthetic/loader",
        "LD_PRELOAD": "/synthetic/loader",
    ]

    @Test func fixtureCarrierUsesOnlyTheSelectedVersionParentWithoutChangingOwnedState() throws {
        let environment = try CameraCarrierLaunchEnvironment.make(
            inherited: inherited, fixture: true, selectedSource: source, carrier: source)
        #expect(
            environment["EDITH_EXTENSION_FIXTURE_HOME"] == source.deletingLastPathComponent().path)
        #expect(source.path.hasPrefix(environment["EDITH_EXTENSION_FIXTURE_HOME"]! + "/"))
        for key in ["HOME", "EDITH_SHARED_DEFAULTS_SUITE", "EDITH_EXTENSION_DATA_ROOT", "PATH"] {
            #expect(environment[key] == inherited[key])
        }
        #expect(!environment.keys.contains { $0.hasPrefix("DYLD_") || $0 == "LD_PRELOAD" })
    }

    @Test func anotherVersionOrUninstalledCarrierCannotReplaceTheSelectedFixture() {
        for carrier in [
            URL(fileURLWithPath: "/synthetic/extensions/virtualCamera/1.1.0/CameraCarrier.app"),
            URL(fileURLWithPath: "/synthetic/owner-home/CameraCarrier.app"),
            URL(fileURLWithPath: "/Applications/Edith Extensions/synthetic.cameraCarrier.app"),
        ] {
            #expect(throws: (any Error).self) {
                try CameraCarrierLaunchEnvironment.make(
                    inherited: inherited, fixture: true, selectedSource: source, carrier: carrier)
            }
        }
    }

    @Test func malformedFixtureInputsRejectInsteadOfSelectingProductionBehavior() {
        for selected in [
            URL(fileURLWithPath: "/synthetic/1.0.0/Other.app"),
            URL(fileURLWithPath: "/CameraCarrier.app"),
            URL(string: "https://example.test/CameraCarrier.app")!,
            URL(fileURLWithPath: "/synthetic/1.0.0/../1.1.0/CameraCarrier.app"),
        ] {
            #expect(throws: (any Error).self) {
                try CameraCarrierLaunchEnvironment.make(
                    inherited: inherited, fixture: true, selectedSource: selected, carrier: selected
                )
            }
        }
        for home in [nil, "relative-home", ""] as [String?] {
            var environment = inherited
            environment["EDITH_EXTENSION_FIXTURE_HOME"] = home
            #expect(throws: (any Error).self) {
                try CameraCarrierLaunchEnvironment.make(
                    inherited: environment, fixture: true, selectedSource: source, carrier: source)
            }
        }
    }

    @Test func anOwnedSymlinkCannotChangeTheCanonicalSelectedVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.resolvingSymlinksInPath().appendingPathComponent(
            "1.0.0/CameraCarrier.app")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let alias = root.resolvingSymlinksInPath().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: selected.deletingLastPathComponent())
        let aliasedCarrier = alias.appendingPathComponent("CameraCarrier.app")
        #expect(throws: (any Error).self) {
            try CameraCarrierLaunchEnvironment.make(
                inherited: inherited, fixture: true, selectedSource: aliasedCarrier,
                carrier: aliasedCarrier)
        }
        let environment = try CameraCarrierLaunchEnvironment.make(
            inherited: inherited, fixture: true, selectedSource: selected, carrier: selected)
        #expect(
            environment["EDITH_EXTENSION_FIXTURE_HOME"] == selected.deletingLastPathComponent().path
        )
    }

    @Test func productionLaunchKeepsItsOriginalEnvironmentExceptLoaderVariables() throws {
        let carrier = URL(
            fileURLWithPath: "/Applications/Edith Extensions/synthetic.cameraCarrier.app")
        let environment = try CameraCarrierLaunchEnvironment.make(
            inherited: inherited, fixture: false, selectedSource: source, carrier: carrier)
        #expect(
            environment["EDITH_EXTENSION_FIXTURE_HOME"] == inherited["EDITH_EXTENSION_FIXTURE_HOME"]
        )
        #expect(environment["HOME"] == inherited["HOME"])
        #expect(!environment.keys.contains { $0.hasPrefix("DYLD_") || $0 == "LD_PRELOAD" })
    }
}
