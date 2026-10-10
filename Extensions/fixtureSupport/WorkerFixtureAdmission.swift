import CoreFoundation
import Darwin
import Foundation

public enum WorkerFixtureError: Error { case invalid }

public enum WorkerFixtureRole: String, Sendable { case helper, app }

public struct WorkerFixtureAdmission: Sendable {
    public let role: WorkerFixtureRole
    public let extensionID: String
    public let home: URL
    public let dataDirectory: URL

    private init(extensionID: String, role: WorkerFixtureRole, home: URL, dataDirectory: URL) {
        self.role = role
        self.extensionID = extensionID
        self.home = home
        self.dataDirectory = dataDirectory
    }

    public static func current(
        extensionID: String, context: NSDictionary, roleBundle: Bundle
    ) throws -> Self? {
        try admit(
            extensionID: extensionID, context: context,
            environment: ProcessInfo.processInfo.environment,
            hostIdentifier: Bundle.main.bundleIdentifier, hostBundle: Bundle.main.bundleURL,
            roleDirectory: roleBundle.bundleURL, roleIdentifier: roleBundle.bundleIdentifier,
            version: roleBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            hostABI: roleBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String)
    }

    public static func admit(
        extensionID: String, context: NSDictionary, environment: [String: String],
        hostIdentifier: String?, hostBundle: URL, roleDirectory: URL,
        roleIdentifier: String?, version: String?, hostABI: String?
    ) throws -> Self? {
        guard
            environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
                || hostIdentifier?.hasPrefix("com.pulkit.edith.tests.") == true
                || (context["hostIdentifier"] as? String)?.hasPrefix("com.pulkit.edith.tests.")
                    == true
        else { return nil }
        let prefix = "com.pulkit.edith.tests.worker-"
        let helperIDs: Set<String> = [
            "focusDim", "micMute", "systemStats", "windowSweaters", "colorPicker",
            "emoji", "presenter", "keystrokeHighlight",
        ]
        let role: WorkerFixtureRole = extensionID == "music" ? .app : .helper
        guard (helperIDs.contains(extensionID) || extensionID == "music"),
            let identifier = hostIdentifier,
            identifier.hasPrefix(prefix),
            UUID(uuidString: String(identifier.dropFirst(prefix.count))) != nil,
            context["hostIdentifier"] as? String == identifier,
            environment["EDITH_APPLICATION_IDENTIFIER"] == identifier,
            environment["EDITH_EXTENSION_ID"] == extensionID,
            context["defaultsSuite"] as? String == identifier + ".extensions." + extensionID,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == identifier + ".extensions." + extensionID,
            let homePath = environment["EDITH_EXTENSION_FIXTURE_HOME"],
            let dataPath = environment["EDITH_EXTENSION_DATA_ROOT"],
            context["dataDirectory"] as? String == dataPath,
            roleIdentifier == "com.pulkit.edith.extensions." + extensionID + "." + role.rawValue,
            let version, validComponent(version), let hostABI, validComponent(hostABI)
        else { throw WorkerFixtureError.invalid }
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        let root = home.deletingLastPathComponent()
        let data = URL(fileURLWithPath: dataPath, isDirectory: true)
        guard homePath == home.path, home.lastPathComponent == extensionID + "-home",
            root.path != "/", root.path != FileManager.default.homeDirectoryForCurrentUser.path,
            hostBundle == root.appendingPathComponent("Fixture.app", isDirectory: true),
            data.path.hasPrefix(root.path + "/"), roleDirectory.path.hasPrefix(root.path + "/"),
            roleDirectory.path.hasSuffix(
                "/Extensions/" + extensionID + "/" + hostABI + "/arm64/" + version + "/"
                    + extensionID
                    + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/"
                    + extensionID + "/" + role.rawValue + ".bundle")
        else { throw WorkerFixtureError.invalid }
        for directory in [root, home, data, hostBundle, roleDirectory] {
            try validate(directory, directory: true)
        }
        guard try mode(home) == 0o700 else { throw WorkerFixtureError.invalid }
        let marker = home.appendingPathComponent("worker-fixture.json")
        try validate(marker, directory: false)
        guard try mode(marker) == 0o600 else { throw WorkerFixtureError.invalid }
        let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 16_384
        else { throw WorkerFixtureError.invalid }
        let descriptor = open(marker.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WorkerFixtureError.invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let bytes = try handle.read(upToCount: 16_385) ?? Data()
        guard bytes.count == size.intValue,
            let values = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(values.keys) == [
                "schema", "hostIdentifier", "extensionID", "dataDirectory", "roleDirectory",
                "version", "hostABI",
            ],
            let schema = values["schema"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
            values["hostIdentifier"] as? String == identifier,
            values["extensionID"] as? String == extensionID,
            values["dataDirectory"] as? String == data.path,
            values["roleDirectory"] as? String == roleDirectory.path,
            values["version"] as? String == version, values["hostABI"] as? String == hostABI
        else { throw WorkerFixtureError.invalid }
        return Self(extensionID: extensionID, role: role, home: home, dataDirectory: data)
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value != "." && value != ".."
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".")
            }
    }

    private static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let value = attributes[.posixPermissions] as? NSNumber else {
            throw WorkerFixtureError.invalid
        }
        return value.intValue
    }

    private static func validate(_ url: URL, directory: Bool) throws {
        guard url.isFileURL, url.path == url.standardizedFileURL.path,
            url.path == url.resolvingSymlinksInPath().path
        else { throw WorkerFixtureError.invalid }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard
            attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0
        else { throw WorkerFixtureError.invalid }
    }
}
