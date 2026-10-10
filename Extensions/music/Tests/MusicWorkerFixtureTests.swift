import Darwin
import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport

@testable import MusicExtension

@MainActor @Suite(.serialized) struct MusicWorkerFixtureTests {
    private enum FactoryProbe: Error { case reached }

    @Test func admittedMusicWorkerHasNoLiveDependenciesAndRejectsEveryFeatureEffect() async throws {
        let fixture = try MusicWorkerFixture()
        defer { fixture.remove() }
        var admissions = 0
        var factories = 0
        let worker = try MusicWorker(
            admission: {
                admissions += 1; return try fixture.admit()
            },
            makeLiveResources: {
                factories += 1; throw FactoryProbe.reached
            })
        #expect(admissions == 1)
        #expect(factories == 0)
        #expect(worker.isInertFixture)
        #expect(worker.liveDependencyCount == 0)
        #expect(worker.browserPresentation == nil)
        #expect(worker.videoPresentation == nil)
        let tile = SurfaceTile(.music)
        await #expect(throws: (any Error).self) { try await worker.read(tile) }
        await #expect(throws: (any Error).self) { try await worker.readNotch(tile) }
        await #expect(throws: (any Error).self) { try await worker.retryNotch(tile) }
        #expect(worker.notchAppIcon("external.spotify") == nil)
        #expect(worker.notchAppIcon("external.music") == nil)
        await #expect(throws: (any Error).self) {
            try await worker.streamingThumbnail(URL(string: "https://example.invalid/mock.png")!)
        }
        for source in ["local", "spotify", "external.spotify", "external.music", "youtubeMusic"] {
            for action in ["open", "openPlayer", "toggle", "next", "seek", "volume", "playQueue"] {
                await #expect(throws: (any Error).self) {
                    try await worker.perform(
                        MusicSurfaceCommand(sourceID: source, trackKey: "Mock", action: action))
                }
            }
        }
        worker.stop(); await worker.shutdown(); worker.stop()
        #expect(worker.liveDependencyCount == 0)
        #expect(factories == 0)
    }

    @Test func invalidIntentThrowsBeforeTheDependencyFactoryCanRun() throws {
        let fixture = try MusicWorkerFixture()
        defer { fixture.remove() }
        let original = fixture.marker
        var factories = 0
        func rejected(_ admission: () throws -> WorkerFixtureAdmission?) {
            #expect(throws: (any Error).self) {
                _ = try MusicWorker(
                    admission: admission,
                    makeLiveResources: {
                        factories += 1; throw FactoryProbe.reached
                    })
            }
            #expect(factories == 0)
        }
        for (key, value) in [
            ("schema", true as Any), ("schema", 2), ("extensionID", "emoji"),
            ("hostIdentifier", "com.pulkit.edith.tests.worker-" + UUID().uuidString),
            ("version", "stale"), ("hostABI", "foreign"),
            ("dataDirectory", fixture.root.appendingPathComponent("foreign").path),
            (
                "roleDirectory",
                fixture.role.deletingLastPathComponent().appendingPathComponent("helper.bundle")
                    .path
            ),
            ("extra", true),
        ] {
            fixture.marker = original; fixture.marker[key] = value; try fixture.writeMarker()
            rejected { try fixture.admit() }
        }
        fixture.marker = original; try fixture.writeMarker()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: fixture.markerURL.path)
        rejected { try fixture.admit() }
        try fixture.writeMarker()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.home.path)
        rejected { try fixture.admit() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.home.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
        rejected { try fixture.admit() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        try Data(repeating: 32, count: 16_385).write(to: fixture.markerURL)
        rejected { try fixture.admit() }
        try fixture.writeMarker()
        let saved = fixture.home.appendingPathComponent("saved-marker.json")
        try FileManager.default.moveItem(at: fixture.markerURL, to: saved)
        try FileManager.default.createSymbolicLink(at: fixture.markerURL, withDestinationURL: saved)
        rejected { try fixture.admit() }
        try FileManager.default.removeItem(at: fixture.markerURL)
        rejected { try fixture.admit() }
        try fixture.writeMarker()
        for key in [
            "EDITH_APPLICATION_IDENTIFIER", "EDITH_EXTENSION_ID", "EDITH_SHARED_DEFAULTS_SUITE",
            "EDITH_EXTENSION_DATA_ROOT",
        ] {
            var environment = fixture.environment; environment[key] = "foreign"
            rejected { try fixture.admit(environment: environment) }
        }
        var context = fixture.context; context["dataDirectory"] = fixture.root.path
        rejected { try fixture.admit(context: context) }
        var environment = fixture.environment
        environment["EDITH_EXTENSION_FIXTURE_HOME"] =
            fixture.outer.appendingPathComponent("music-home").path
        rejected { try fixture.admit(environment: environment) }
        environment = fixture.environment; environment["EDITH_EXTENSION_FIXTURE_HOME"] = nil
        rejected { try fixture.admit(environment: environment) }
    }

    @Test func productionWithoutFixtureIntentReachesTheRealDependencyFactory() throws {
        var factories = 0
        #expect(throws: FactoryProbe.self) {
            _ = try MusicWorker(
                admission: {
                    try WorkerFixtureAdmission.admit(
                        extensionID: "music", context: [:], environment: [:],
                        hostIdentifier: "com.pulkit.edith.production-fixture-free",
                        hostBundle: URL(fileURLWithPath: "/unused/Fixture.app"),
                        roleDirectory: URL(fileURLWithPath: "/unused/app.bundle"),
                        roleIdentifier: nil, version: nil, hostABI: nil)
                },
                makeLiveResources: {
                    factories += 1; throw FactoryProbe.reached
                })
        }
        #expect(factories == 1)
    }

    @Test func testNamespaceWithoutMarkerCannotFallBackToProduction() throws {
        var factories = 0
        #expect(throws: WorkerFixtureError.self) {
            _ = try MusicWorker(
                admission: {
                    try MusicWorker.resolveFixture(
                        admission: { nil },
                        applicationIdentifier: "com.pulkit.edith.tests.worker-" + UUID().uuidString)
                },
                makeLiveResources: {
                    factories += 1; throw FactoryProbe.reached
                })
        }
        #expect(factories == 0)
    }

    @Test func actualConstructorRejectsInvalidProcessFixtureBeforeProductionValidation() throws {
        #expect(ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil)
        var validations = 0
        #expect(throws: WorkerFixtureError.self) {
            _ = try MusicWorker(
                context: [:], roleBundle: Bundle(for: MusicWorker.self),
                validateProduction: {
                    validations += 1; throw FactoryProbe.reached
                })
        }
        #expect(validations == 0)
    }

    @Test func helperRoleAdmissionCannotBecomeAMusicWorker() throws {
        let fixture = try MusicWorkerFixture(owner: "focusDim")
        defer { fixture.remove() }
        let admission = try #require(try fixture.admit(owner: "focusDim"))
        #expect(admission.role == .helper)
        var factories = 0
        #expect(throws: WorkerFixtureError.self) {
            _ = try MusicWorker(
                admission: { admission },
                makeLiveResources: {
                    factories += 1; throw FactoryProbe.reached
                })
        }
        #expect(factories == 0)
    }
}

private final class MusicWorkerFixture {
    let outer: URL
    let root: URL
    let home: URL
    let data: URL
    let role: URL
    let identifier = "com.pulkit.edith.tests.worker-" + UUID().uuidString
    var marker: [String: Any]
    var environment: [String: String]
    var context: [String: Any]
    var markerURL: URL { home.appendingPathComponent("worker-fixture.json") }

    init(owner: String = "music") throws {
        outer = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("music-inert-admission-" + UUID().uuidString)
        root = outer.appendingPathComponent(owner + "-host")
        home = root.appendingPathComponent(owner + "-home")
        data = root.appendingPathComponent("support/Data/" + owner)
        let selected = owner == "music" ? "app" : "helper"
        role = root.appendingPathComponent(
            "support/Extensions/" + owner + "/edith-host-2/arm64/1.0.0/" + owner
                + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/"
                + owner + "/" + selected + ".bundle")
        for directory in [home, data, role, root.appendingPathComponent("Fixture.app")] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        context = [
            "hostIdentifier": identifier, "defaultsSuite": identifier + ".extensions." + owner,
            "dataDirectory": data.path,
        ]
        environment = [
            "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": owner,
            "EDITH_SHARED_DEFAULTS_SUITE": identifier + ".extensions." + owner,
            "EDITH_EXTENSION_FIXTURE_HOME": home.path, "EDITH_EXTENSION_DATA_ROOT": data.path,
        ]
        marker = [
            "schema": 1, "hostIdentifier": identifier, "extensionID": owner,
            "dataDirectory": data.path, "roleDirectory": role.path, "version": "1.0.0",
            "hostABI": "edith-host-2",
        ]
        try writeMarker()
    }

    func writeMarker() throws {
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
    }

    func admit(
        owner: String = "music", environment: [String: String]? = nil, context: [String: Any]? = nil
    ) throws -> WorkerFixtureAdmission? {
        try WorkerFixtureAdmission.admit(
            extensionID: owner, context: (context ?? self.context) as NSDictionary,
            environment: environment ?? self.environment, hostIdentifier: identifier,
            hostBundle: root.appendingPathComponent("Fixture.app"), roleDirectory: role,
            roleIdentifier: "com.pulkit.edith.extensions." + owner + "."
                + (owner == "music" ? "app" : "helper"),
            version: "1.0.0", hostABI: "edith-host-2")
    }

    func remove() { try? FileManager.default.removeItem(at: outer) }
}
