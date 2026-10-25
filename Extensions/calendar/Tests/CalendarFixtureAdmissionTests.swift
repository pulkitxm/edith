import Foundation
import Testing

@testable import CalendarExtension

@Suite struct CalendarFixtureAdmissionTests {
    @Test func exactOwnedRemoteFixtureAdmitsOnlyItsBoundCalendarPackage() throws {
        let fixture = try CalendarAdmissionFixture()
        defer { fixture.remove() }
        let admission = try #require(try fixture.admit())
        #expect(admission.home == fixture.home)
        #expect(admission.dataDirectory == fixture.data)
        #expect(admission.packageDirectory == fixture.package)
    }

    @Test func ordinaryProductionDoesNotInspectAnyFixturePaths() throws {
        let admission = try CalendarFixtureAdmission.admit(
            context: ["hostIdentifier": "com.pulkit.edith"], environment: [:],
            hostIdentifier: "com.pulkit.edith",
            hostBundle: URL(fileURLWithPath: "/absent/Host.app"),
            roleBundle: URL(fileURLWithPath: "/absent/app.bundle"), roleIdentifier: nil,
            hostABI: nil, version: nil)
        #expect(admission == nil)
    }

    @Test func foreignHostEnvironmentContextAndDataCannotEnableFixtureServices() throws {
        let fixture = try CalendarAdmissionFixture()
        defer { fixture.remove() }
        for key in [
            "EDITH_APPLICATION_IDENTIFIER", "EDITH_SHARED_DEFAULTS_SUITE", "EDITH_EXTENSION_ID",
            "EDITH_EXTENSION_DATA_ROOT", "EDITH_EXTENSION_FIXTURE_HOME",
        ] {
            var environment = fixture.environment
            environment[key] = "foreign"
            #expect(throws: (any Error).self) { try fixture.admit(environment: environment) }
        }
        for key in ["hostIdentifier", "defaultsSuite", "dataDirectory"] {
            let context = fixture.context.mutableCopy() as! NSMutableDictionary
            context[key] = "foreign"
            #expect(throws: (any Error).self) { try fixture.admit(context: context) }
        }
        #expect(throws: (any Error).self) {
            try fixture.admit(hostIdentifier: "com.pulkit.edith.tests.remote-foreign")
        }
        #expect(throws: (any Error).self) { try fixture.admit(environment: [:]) }
        #expect(throws: (any Error).self) {
            try fixture.admit(
                roleBundle: fixture.directory.appendingPathComponent("foreign.bundle"))
        }
    }

    @Test func rootHomeMissingMarkerForeignMarkerAndExtraFieldsReject() throws {
        let fixture = try CalendarAdmissionFixture()
        defer { fixture.remove() }
        var environment = fixture.environment
        environment["EDITH_EXTENSION_FIXTURE_HOME"] = "/"
        #expect(throws: (any Error).self) { try fixture.admit(environment: environment) }
        environment["EDITH_EXTENSION_FIXTURE_HOME"] = "/synthetic-data"
        #expect(throws: (any Error).self) { try fixture.admit(environment: environment) }
        try FileManager.default.removeItem(at: fixture.marker)
        #expect(throws: (any Error).self) { try fixture.admit() }
        for key in ["hostIdentifier", "dataDirectory", "packageDirectory"] {
            var values = fixture.markerValues
            values[key] = "foreign"
            try fixture.writeMarker(values)
            #expect(throws: (any Error).self) { try fixture.admit() }
        }
        var values = fixture.markerValues
        values["extra"] = "ignored"
        try fixture.writeMarker(values)
        #expect(throws: (any Error).self) { try fixture.admit() }
        values = fixture.markerValues
        values["schema"] = true
        try fixture.writeMarker(values)
        #expect(throws: (any Error).self) { try fixture.admit() }
        try fixture.writeMarker(fixture.markerValues)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: fixture.marker.path)
        #expect(throws: (any Error).self) { try fixture.admit() }
        try fixture.writeMarker(fixture.markerValues)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.home.path)
        #expect(throws: (any Error).self) { try fixture.admit() }
    }

    @Test func symlinkHomeDataPackageHostAndMarkerRejectEvenWhenTargetIsOwned() throws {
        for path in ["home", "data", "package", "host", "marker"] {
            let fixture = try CalendarAdmissionFixture()
            defer { fixture.remove() }
            let original: URL
            switch path {
            case "home": original = fixture.home
            case "data": original = fixture.data
            case "package": original = fixture.package
            case "host": original = fixture.host
            default: original = fixture.marker
            }
            let target = fixture.directory.appendingPathComponent("owned-target-" + path)
            try FileManager.default.moveItem(at: original, to: target)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
            #expect(throws: (any Error).self) { try fixture.admit() }
        }
    }
}

struct CalendarAdmissionFixture {
    let identifier = "com.pulkit.edith.tests.remote-" + UUID().uuidString.lowercased()
    let directory: URL
    let home: URL
    let host: URL
    let data: URL
    let package: URL
    let role: URL
    var marker: URL { home.appendingPathComponent("calendar-fixture.json") }
    var context: NSDictionary {
        [
            "hostIdentifier": identifier, "defaultsSuite": identifier + ".extensions.calendar",
            "dataDirectory": data.path,
        ]
    }
    var environment: [String: String] {
        [
            "EDITH_APPLICATION_IDENTIFIER": identifier,
            "EDITH_SHARED_DEFAULTS_SUITE": identifier + ".extensions.calendar",
            "EDITH_EXTENSION_ID": "calendar", "EDITH_EXTENSION_FIXTURE_HOME": home.path,
            "EDITH_EXTENSION_DATA_ROOT": data.path,
        ]
    }
    var markerValues: [String: Any] {
        [
            "schema": 1, "hostIdentifier": identifier, "dataDirectory": data.path,
            "packageDirectory": package.path,
        ]
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("calendar-admission-" + UUID().uuidString)
        home = directory.appendingPathComponent("synthetic-data", isDirectory: true)
        host = directory.appendingPathComponent("Host.app", isDirectory: true)
        let identity = directory.appendingPathComponent(
            "support/Edith Tests/" + String(identifier.dropFirst("com.pulkit.edith.tests.".count)))
        data = identity.appendingPathComponent("Data/calendar", isDirectory: true)
        package = identity.appendingPathComponent(
            "Extensions/calendar/host-v2/arm64/1.0.0/calendar", isDirectory: true)
        role = package.appendingPathComponent(
            "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/calendar/app.bundle",
            isDirectory: true)
        for url in [home, host, data, role] {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try writeMarker(markerValues)
    }

    func writeMarker(_ values: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    func admit(
        environment: [String: String]? = nil, context: NSDictionary? = nil,
        hostIdentifier: String? = nil, roleBundle: URL? = nil
    ) throws -> CalendarFixtureAdmission? {
        try CalendarFixtureAdmission.admit(
            context: context ?? self.context, environment: environment ?? self.environment,
            hostIdentifier: hostIdentifier ?? identifier, hostBundle: host,
            roleBundle: roleBundle ?? role,
            roleIdentifier: "com.pulkit.edith.extensions.calendar.app", hostABI: "host-v2",
            version: "1.0.0")
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
