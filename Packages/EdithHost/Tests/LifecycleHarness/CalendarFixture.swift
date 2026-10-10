import Darwin
import EdithHostCore
import EdithExtensionSupport
import ExtensionMarketplace
import Foundation

enum CalendarLifecycleFixtureError: Error {
    case identity, package, marker, path
}

struct CalendarLifecycleFixture {
    static func canonicalDirectory(_ requested: URL) -> URL {
        requested.resolvingSymlinksInPath()
    }

    let directory: URL
    let identity: HostIdentity

    var home: URL { directory.appendingPathComponent("synthetic-data") }
    var app: URL { directory.appendingPathComponent("Host.app") }

    init(directory: URL, identity: HostIdentity) throws {
        let prefix = "com.pulkit.edith.tests.remote-"
        guard identity.identifier.hasPrefix(prefix),
            UUID(uuidString: String(identity.identifier.dropFirst(prefix.count))) != nil,
            directory.path == directory.resolvingSymlinksInPath().path,
            identity.root.path
                == directory.appendingPathComponent("support/Edith Tests")
                .appendingPathComponent(
                    String(identity.identifier.dropFirst("com.pulkit.edith.tests.".count))
                ).path
        else { throw CalendarLifecycleFixtureError.identity }
        self.directory = directory; self.identity = identity
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Self.validate(home, directory: true, mode: 0o700)
    }

    func prepare(package: ExtensionPackage, store: ExtensionPackageStore) throws {
        guard package.id == "calendar", package.architecture == "arm64",
            ExtensionPackage.validComponent(package.hostABI),
            ExtensionPackage.validComponent(package.version)
        else {
            throw CalendarLifecycleFixtureError.package
        }
        let data = identity.extensionDirectory("calendar")
        let selected = store.directory(for: package).appendingPathComponent("calendar")
        let expected = identity.root.appendingPathComponent("Extensions/calendar")
            .appendingPathComponent(package.hostABI).appendingPathComponent(package.architecture)
            .appendingPathComponent(package.version).appendingPathComponent("calendar")
        guard selected.path == expected.path else { throw CalendarLifecycleFixtureError.package }
        try FileManager.default.createDirectory(
            at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for path in [directory, home, app, identity.root, data, selected] {
            try Self.validate(path, directory: true)
        }
        let marker = home.appendingPathComponent("calendar-fixture.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            try Self.validate(marker, directory: false, mode: 0o600)
            let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 16_384,
                let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: marker))
                    as? [String: Any],
                Set(existing.keys) == [
                    "schema", "hostIdentifier", "dataDirectory", "packageDirectory",
                ],
                existing["schema"] as? Int == 1,
                existing["hostIdentifier"] as? String == identity.identifier,
                existing["dataDirectory"] as? String == data.path,
                let oldPath = existing["packageDirectory"] as? String,
                oldPath.hasPrefix(
                    identity.root.appendingPathComponent("Extensions/calendar").path + "/"),
                oldPath == URL(fileURLWithPath: oldPath).standardizedFileURL.path
            else { throw CalendarLifecycleFixtureError.marker }
        }
        let bytes = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "hostIdentifier": identity.identifier,
            "dataDirectory": data.path, "packageDirectory": selected.path,
        ])
        let temporary = home.appendingPathComponent(UUID().uuidString)
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: bytes, attributes: [.posixPermissions: 0o600])
        else { throw CalendarLifecycleFixtureError.marker }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, marker.path) == 0 else {
            throw CalendarLifecycleFixtureError.path
        }
        try Self.validate(marker, directory: false, mode: 0o600)
    }

    private static func validate(_ path: URL, directory: Bool, mode: Int? = nil) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard path.path == path.resolvingSymlinksInPath().path,
            attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            let permissions = attributes[.posixPermissions] as? NSNumber,
            permissions.intValue & 0o022 == 0,
            mode == nil || permissions.intValue == mode
        else { throw CalendarLifecycleFixtureError.path }
    }
}

extension HostLifecycleHarness {
    @MainActor static func verifyCalendar(_ endpoint: ExtensionPeerEndpoint) async throws {
        for (days, includesLaterEvent) in [(7, false), (30, true)] {
            let request = try ExtensionCLIRequest(
                arguments: ["ls", "--days", String(days), "--json"], workingDirectory: "/tmp")
            let reply = try JSONDecoder().decode(
                ExtensionCLIReply.self,
                from: await endpoint.invoke("calendar.cli", payload: JSONEncoder().encode(request)))
            guard reply.exitCode == 0, reply.stderr.isEmpty,
                let events = try JSONSerialization.jsonObject(with: Data(reply.stdout.utf8))
                    as? [[String: Any]],
                events.contains(where: { $0["id"] as? String == "synthetic-calendar-meeting" }),
                events.contains(where: { $0["id"] as? String == "synthetic-calendar-next-page" })
                    == includesLaterEvent
            else { throw HostWorkerError.invalidResponse }
        }
        let catalog =
            try JSONSerialization.jsonObject(
                with: await endpoint.invoke("calendar.cli.catalog", payload: Data("{}".utf8)))
            as? [String: Any]
        guard let commands = catalog?["commands"] as? [[String: Any]],
            commands.contains(where: { $0["route"] as? [String] == ["calendar", "ls"] })
        else { throw HostWorkerError.invalidResponse }
    }
}
