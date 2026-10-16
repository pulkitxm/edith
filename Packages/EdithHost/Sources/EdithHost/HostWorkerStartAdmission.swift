import CoreFoundation
import Darwin
import Foundation
import WorkerFixtureSupport

enum HostWorkerStartAdmission {
    enum Failure: Error { case rejected }

    static let fixtureOwners: Set<String> = [
        "focusDim", "windowSweaters", "micMute", "keystrokeHighlight", "presenter", "colorPicker",
        "systemStats", "emoji", "music", "plugins", "studio", "keepAwake", "audioMixer", "homebrew",
        "calendar", "jev", "system", "timeLapse", "cleaner", "appMaintenance", "blitztree",
        "notchShelf",
        "clipboard", "docs", "latex", "companion", "terminal", "usage", "bifrost", "lidAwake",
        "attention",
        "machines", "downloads", "seoAudit", "virtualCamera", "codeStats", "herdr", "quinjet",
        "database",
    ]

    static func perform<Role>(
        admit: () throws -> [Role], appearance: () throws -> Void,
        start: (Role) throws -> Void
    ) throws {
        let roles = try admit()
        guard !roles.isEmpty else { throw Failure.rejected }
        try appearance()
        for role in roles { try start(role) }
    }

    struct FixtureRole {
        let directory: URL
        let identifier: String?
        let version: String?
        let hostABI: String?
    }

    static func hasFixtureIntent(identifier: String, environment: [String: String]) -> Bool {
        environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
            || identifier.hasPrefix("com.pulkit.edith.tests.")
            || environment["EDITH_APPLICATION_IDENTIFIER"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
            || environment["EDITH_SHARED_DEFAULTS_SUITE"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
    }

    static func admitFixture(
        identifier: String, owner: String, version: String, hostABI: String,
        supportDirectory: URL, hostBundle: URL, dataDirectory: URL, defaultsSuite: String,
        roles: [FixtureRole], environment: [String: String]
    ) throws {
        let calendar = owner == "calendar"
        let prefix = "com.pulkit.edith.tests." + (calendar ? "remote-" : "worker-")
        guard fixtureOwners.contains(owner), identifier.hasPrefix(prefix),
            UUID(uuidString: String(identifier.dropFirst(prefix.count))) != nil,
            validComponent(owner), validComponent(version), validComponent(hostABI),
            environment["EDITH_APPLICATION_IDENTIFIER"] == identifier,
            environment["EDITH_EXTENSION_ID"] == owner,
            defaultsSuite == identifier + ".extensions." + owner,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == defaultsSuite,
            environment["EDITH_EXTENSION_DATA_ROOT"] == dataDirectory.path,
            let homePath = environment["EDITH_EXTENSION_FIXTURE_HOME"]
        else { throw Failure.rejected }
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        let root = home.deletingLastPathComponent()
        let slot = String(identifier.dropFirst("com.pulkit.edith.tests.".count))
        let support = calendar ? root.appendingPathComponent("support") : root
        let identity = support.appendingPathComponent("Edith Tests/" + slot)
        let package = identity.appendingPathComponent(
            "Extensions/" + owner + "/" + hostABI + "/arm64/" + version + "/" + owner)
        let payload = package.appendingPathComponent(
            "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/"
                + owner)
        guard home.path == homePath,
            home.lastPathComponent == (calendar ? "synthetic-data" : owner + "-home"),
            root.path != "/", root != FileManager.default.homeDirectoryForCurrentUser,
            supportDirectory.path == support.path,
            hostBundle.path
                == root.appendingPathComponent(calendar ? "Host.app" : "Fixture.app").path,
            dataDirectory.path == identity.appendingPathComponent("Data/" + owner).path,
            !roles.isEmpty
        else { throw Failure.rejected }
        for role in roles {
            let name = role.directory.deletingPathExtension().lastPathComponent
            guard ["helper", "agent", "app"].contains(name),
                role.directory.path == payload.appendingPathComponent(name + ".bundle").path,
                role.identifier == "com.pulkit.edith.extensions." + owner + "." + name,
                role.version == version, role.hostABI == hostABI
            else { throw Failure.rejected }
            try validateTree(role.directory, root: root)
        }
        for directory in [home, hostBundle, dataDirectory] {
            try validateTree(directory, root: root)
        }
        guard try mode(home) == 0o700, (try calendar || mode(root) == 0o700) else {
            throw Failure.rejected
        }
        let selected =
            calendar
            ? roles.first(where: { $0.directory.lastPathComponent == "app.bundle" })
            : roles.first(where: { $0.directory.lastPathComponent == "helper.bundle" })
                ?? roles.first(where: { $0.directory.lastPathComponent == "app.bundle" })
        guard let selected else { throw Failure.rejected }
        let marker = home.appendingPathComponent(
            calendar ? "calendar-fixture.json" : "worker-fixture.json")
        try validate(marker, directory: false)
        guard try mode(marker) == 0o600 else { throw Failure.rejected }
        let descriptor = open(marker.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.rejected }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600,
            metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= 16_384
        else { throw Failure.rejected }
        let bytes = try handle.read(upToCount: 16_385) ?? Data()
        guard bytes.count == metadata.st_size,
            let values = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let schema = values["schema"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
            values["hostIdentifier"] as? String == identifier,
            values["dataDirectory"] as? String == dataDirectory.path
        else { throw Failure.rejected }
        if calendar {
            guard
                Set(values.keys) == [
                    "schema", "hostIdentifier", "dataDirectory", "packageDirectory",
                ],
                values["packageDirectory"] as? String == package.path
            else { throw Failure.rejected }
        } else {
            guard
                Set(values.keys) == [
                    "schema", "hostIdentifier", "extensionID", "dataDirectory", "roleDirectory",
                    "version", "hostABI",
                ], values["extensionID"] as? String == owner,
                values["roleDirectory"] as? String == selected.directory.path,
                values["version"] as? String == version, values["hostABI"] as? String == hostABI
            else { throw Failure.rejected }
            let strictOwners: Set<String> = [
                "focusDim", "micMute", "systemStats", "windowSweaters", "colorPicker", "emoji",
                "presenter", "keystrokeHighlight", "keepAwake", "notchShelf", "music", "plugins",
                "studio", "usage", "herdr", "machines", "attention", "companion", "codeStats",
            ]
            if strictOwners.contains(owner) {
                let context: NSDictionary = [
                    "hostIdentifier": identifier, "defaultsSuite": defaultsSuite,
                    "dataDirectory": dataDirectory.path,
                ]
                guard
                    try WorkerFixtureAdmission.admit(
                        extensionID: owner, context: context, environment: environment,
                        hostIdentifier: identifier, hostBundle: hostBundle,
                        roleDirectory: selected.directory, roleIdentifier: selected.identifier,
                        version: selected.version, hostABI: selected.hostABI) != nil
                else { throw Failure.rejected }
            }
        }
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value != "." && value != ".."
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".")
            }
    }

    private static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mode = attributes[.posixPermissions] as? NSNumber else { throw Failure.rejected }
        return mode.intValue
    }

    private static func validateTree(_ url: URL, root: URL) throws {
        guard url.path.hasPrefix(root.path + "/") else { throw Failure.rejected }
        var current = url
        while current.path != root.path {
            try validate(current, directory: true)
            current.deleteLastPathComponent()
        }
        try validate(root, directory: true)
    }

    private static func validate(_ url: URL, directory: Bool) throws {
        guard url.isFileURL, url.path == url.standardizedFileURL.path,
            url.path == url.resolvingSymlinksInPath().path
        else { throw Failure.rejected }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard
            attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0
        else { throw Failure.rejected }
    }
}
