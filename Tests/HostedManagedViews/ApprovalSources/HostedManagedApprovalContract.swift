import CoreFoundation
import Darwin
import Foundation

enum HostedManagedApprovalError: Error, Equatable {
    case untrustedRunner
    case invalidRoute
    case invalidApplication
    case ambiguousIdentity
    case ambiguousControl
    case unsupportedControl
    case timedOut
    case windowClosed
}

struct HostedManagedApprovalRoute: Decodable, Equatable {
    let schema: Int
    let extensionID: String
    let hostIdentifier: String
    let directory: String
    let sourceCommit: String
    let version: String
    let hostABI: String
    let sourceFingerprint: String
    let packageSHA256: String

    static let owners: Set<String> = [
        "keepAwake", "focusDim", "windowSweaters", "micMute", "keystrokeHighlight", "presenter",
        "colorPicker", "systemStats", "emoji", "jev", "audioMixer", "music", "homebrew", "calendar",
        "system", "timeLapse", "cleaner", "appMaintenance", "plugins", "blitztree", "notchShelf",
        "clipboard", "docs", "latex", "companion", "terminal", "usage", "bifrost", "lidAwake",
        "attention", "machines", "downloads", "seoAudit", "virtualCamera", "codeStats", "studio",
        "herdr", "quinjet", "database",
    ]
    var workerIdentifier: String { hostIdentifier + ".extension." + extensionID + ".worker" }
    var extensionPoint: String { hostIdentifier + ".ExtensionUI" }
    var expectedLabel: String { "Edith " + extensionID }
    var windowTitle: String { "Managed " + extensionID + " Approval " + hostIdentifier }

    func validate(environment: [String: String]) throws {
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_OS"] == "macOS",
            environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            environment["GITHUB_REPOSITORY"] == "pulkitxm/edith",
            ["65671483", "320458784"].contains(environment["GITHUB_ACTOR_ID"]),
            environment["GITHUB_EVENT_NAME"] == "workflow_dispatch",
            [
                "refs/heads/main", "refs/heads/feat/extension-marketplace",
                "refs/heads/feat/hosted-managed-view-runner",
                "refs/heads/feat/hosted-managed-view-execution",
            ].contains(environment["GITHUB_REF"]),
            environment["GITHUB_SHA"] == sourceCommit,
            environment["EDITH_HOSTED_MANAGED_VIEWS"] == "1"
        else { throw HostedManagedApprovalError.untrustedRunner }
        let prefix = "com.pulkit.edith.tests." + (extensionID == "calendar" ? "remote-" : "worker-")
        guard schema == 1, Self.owners.contains(extensionID), hostIdentifier.hasPrefix(prefix),
            UUID(uuidString: String(hostIdentifier.dropFirst(prefix.count)))?.uuidString
                .lowercased()
                == String(hostIdentifier.dropFirst(prefix.count)),
            Self.hex(sourceCommit, count: 40), Self.hex(sourceFingerprint, count: 64),
            Self.hex(packageSHA256, count: 64), hostABI == "edith-host-2",
            version.range(of: "^[0-9]{1,8}\\.[0-9]{1,8}\\.[0-9]{1,8}$", options: .regularExpression)
                != nil
        else { throw HostedManagedApprovalError.invalidRoute }
    }

    func validateHostedDirectory(accountHome: URL) throws {
        let prefix = "com.pulkit.edith.tests." + (extensionID == "calendar" ? "remote-" : "worker-")
        let suffix = String(hostIdentifier.dropFirst(prefix.count))
        let expected = accountHome.appendingPathComponent(
            "Applications/Edith Managed Views " + suffix)
        guard accountHome.isFileURL, accountHome.path == accountHome.standardizedFileURL.path,
            accountHome.path == accountHome.resolvingSymlinksInPath().path,
            directory == expected.path
        else { throw HostedManagedApprovalError.invalidRoute }
    }

    func validateHostedDirectory() throws {
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else {
            throw HostedManagedApprovalError.invalidRoute
        }
        try validateHostedDirectory(accountHome: URL(fileURLWithPath: String(cString: path)))
    }

    func applicationEnvironment(_ environment: [String: String]) throws -> [String: String] {
        try validate(environment: environment)
        let root = URL(fileURLWithPath: directory)
        let home = root.appendingPathComponent(
            extensionID == "calendar" ? "synthetic-data" : extensionID + "-home")
        let temporary = root.appendingPathComponent("tmp")
        let paths = [
            root, home, temporary, home.appendingPathComponent(".config"),
            home.appendingPathComponent(".cache"), home.appendingPathComponent(".local"),
            home.appendingPathComponent(".local/share"),
        ]
        for path in paths {
            guard path.path == path.standardizedFileURL.path,
                path.path == path.resolvingSymlinksInPath().path
            else { throw HostedManagedApprovalError.invalidRoute }
            let descriptor = open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw HostedManagedApprovalError.invalidRoute }
            var info = stat()
            let valid =
                fstat(descriptor, &info) == 0 && info.st_uid == getuid()
                && info.st_mode & 0o7777 == 0o700
            close(descriptor)
            guard valid else { throw HostedManagedApprovalError.invalidRoute }
        }
        var result = environment.filter {
            [
                "GITHUB_ACTIONS", "RUNNER_OS", "RUNNER_ENVIRONMENT", "GITHUB_REPOSITORY",
                "GITHUB_ACTOR_ID", "GITHUB_EVENT_NAME", "GITHUB_REF", "GITHUB_SHA",
                "EDITH_HOSTED_MANAGED_VIEWS",
            ].contains($0.key)
        }
        result["HOME"] = home.path
        result["TMPDIR"] = temporary.path
        result["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        result["XDG_CACHE_HOME"] = home.appendingPathComponent(".cache").path
        result["XDG_DATA_HOME"] = home.appendingPathComponent(".local/share").path
        result["EDITH_EXTENSION_FIXTURE_HOME"] = home.path
        result["EDITH_APPLICATION_IDENTIFIER"] = hostIdentifier
        result["EDITH_SHARED_DEFAULTS_SUITE"] = hostIdentifier
        return result
    }

    func validateApplicationPaths(bundle: URL, executable: URL?) throws {
        let expected = URL(fileURLWithPath: directory).appendingPathComponent("Fixture.app")
        let expectedExecutable = expected.appendingPathComponent("Contents/MacOS/Edith")
        guard bundle.isFileURL, bundle.path == expected.path,
            bundle.path == bundle.resolvingSymlinksInPath().path,
            executable?.isFileURL == true, executable?.path == expectedExecutable.path,
            executable?.path == executable?.resolvingSymlinksInPath().path
        else { throw HostedManagedApprovalError.invalidApplication }
    }

    func validateApplication(identifier: String?, descriptor: [String: Any]) throws {
        guard identifier == hostIdentifier, Set(descriptor.keys) == ["EXVersion", extensionPoint],
            let schema = descriptor["EXVersion"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
            let point = descriptor[extensionPoint] as? [String: Any],
            point["EXExtensionPointName"] as? String == "ExtensionUI"
        else { throw HostedManagedApprovalError.invalidApplication }
    }

    func validateIdentities(_ identities: [HostedManagedApprovalIdentity]) throws -> String? {
        guard identities.count <= 1 else { throw HostedManagedApprovalError.ambiguousIdentity }
        guard let identity = identities.first else { return nil }
        guard identity.workerIdentifier == workerIdentifier,
            identity.extensionPoint == extensionPoint,
            identity.label == expectedLabel, !identity.identifier.isEmpty,
            identity.identifier.utf8.count <= 4096
        else { throw HostedManagedApprovalError.ambiguousIdentity }
        return identity.identifier
    }

    static func load(directory: URL, environment: [String: String]) throws -> Self {
        let data = try readOwned(
            directory: directory, name: "managed-route.json", maximumBytes: 16_384)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys)
                == Set([
                    "schema", "extensionID", "hostIdentifier", "directory", "sourceCommit",
                    "version",
                    "hostABI", "sourceFingerprint", "packageSHA256", "location", "section",
                    "factoryOverlay",
                ]), let schema = object["schema"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
            let overlay = object["factoryOverlay"] as? NSNumber,
            CFGetTypeID(overlay) == CFBooleanGetTypeID()
        else { throw HostedManagedApprovalError.invalidRoute }
        let route = try JSONDecoder().decode(Self.self, from: data)
        guard route.directory == directory.path else {
            throw HostedManagedApprovalError.invalidRoute
        }
        try route.validate(environment: environment)
        return route
    }

    static func readOwned(directory: URL, name: String, maximumBytes: Int) throws -> Data {
        guard ["managed-route.json", "ExtensionUI.appextensionpoints"].contains(name),
            directory.isFileURL, directory.path == directory.standardizedFileURL.path,
            directory.path == directory.resolvingSymlinksInPath().path,
            maximumBytes > 0, maximumBytes <= 65_536
        else { throw HostedManagedApprovalError.invalidRoute }
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw HostedManagedApprovalError.invalidRoute }
        defer { close(root) }
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0, rootInfo.st_uid == getuid(),
            rootInfo.st_mode & 0o022 == 0
        else { throw HostedManagedApprovalError.invalidRoute }
        let descriptor = openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw HostedManagedApprovalError.invalidRoute }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_uid == getuid(), before.st_nlink == 1,
            before.st_mode & S_IFMT == S_IFREG, before.st_mode & 0o022 == 0,
            before.st_size > 0, before.st_size <= maximumBytes,
            name != "managed-route.json"
                || (before.st_mode & 0o7777 == 0o600 && rootInfo.st_mode & 0o7777 == 0o700),
            let bytes = try handle.read(upToCount: maximumBytes + 1), bytes.count == before.st_size
        else { throw HostedManagedApprovalError.invalidRoute }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev,
            before.st_ino == after.st_ino, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        else { throw HostedManagedApprovalError.invalidRoute }
        return bytes
    }

    private static func hex(_ value: String, count: Int) -> Bool {
        value.count == count && value.allSatisfy { $0.isASCII && "0123456789abcdef".contains($0) }
    }
}

struct HostedManagedApprovalIdentity: Sendable {
    let identifier: String
    let workerIdentifier: String
    let extensionPoint: String
    let label: String
}

struct HostedManagedApprovalControl {
    let kind: String
    let labels: [String]
    let value: String?
    let enabled: Bool
    let hittable: Bool
}

enum HostedManagedApprovalSelection {
    static func select(_ controls: [HostedManagedApprovalControl], expectedLabel: String) throws
        -> Int
    {
        guard controls.count <= 128, !expectedLabel.isEmpty else {
            throw HostedManagedApprovalError.ambiguousControl
        }
        let matches = controls.indices.filter { controls[$0].labels.contains(expectedLabel) }
        guard matches.count == 1, let index = matches.first else {
            throw HostedManagedApprovalError.ambiguousControl
        }
        let control = controls[index]
        guard ["checkbox", "switch"].contains(control.kind), control.enabled, control.hittable,
            control.value == "0"
        else { throw HostedManagedApprovalError.unsupportedControl }
        return index
    }
}

struct HostedManagedApprovalReceipt: Codable, Equatable {
    let schema: Int
    let sourceCommit: String
    let extensionID: String
    let selectedVersion: String
    let hostABI: String
    let sourceFingerprint: String
    let packageSHA256: String
    let hostIdentifier: String
    let workerIdentifier: String
    let extensionPointIdentifier: String
    let expectedLabel: String
    let hostPID: Int32
    let hostGeneration: String
    let outcome: String
    let publicBrowser: Bool
    let publicDiscovery: Bool
    let ownedBrowserClosed: Bool
    let activationPolicyRestored: Bool
    let managedViewReady: Bool

    static func approved(
        _ data: Data, route: HostedManagedApprovalRoute, hostPID: Int32, hostGeneration: String
    ) throws -> Self {
        guard !data.isEmpty, data.count <= 16_384,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys)
                == Set([
                    "schema", "sourceCommit", "extensionID", "selectedVersion", "hostABI",
                    "sourceFingerprint", "packageSHA256", "hostIdentifier", "workerIdentifier",
                    "extensionPointIdentifier", "expectedLabel", "hostPID", "hostGeneration",
                    "outcome", "publicBrowser", "publicDiscovery", "ownedBrowserClosed",
                    "activationPolicyRestored", "managedViewReady",
                ])
        else { throw HostedManagedApprovalError.invalidRoute }
        let receipt = try JSONDecoder().decode(Self.self, from: data)
        guard receipt.schema == 1, receipt.sourceCommit == route.sourceCommit,
            receipt.extensionID == route.extensionID, receipt.selectedVersion == route.version,
            receipt.hostABI == route.hostABI, receipt.sourceFingerprint == route.sourceFingerprint,
            receipt.packageSHA256 == route.packageSHA256,
            receipt.hostIdentifier == route.hostIdentifier,
            receipt.workerIdentifier == route.workerIdentifier,
            receipt.extensionPointIdentifier == route.extensionPoint,
            receipt.expectedLabel == route.expectedLabel, hostPID > 1,
            receipt.hostPID == hostPID, receipt.hostGeneration == hostGeneration,
            hostGeneration.range(of: "^[0-9]{1,20}\\.[0-9]{1,6}$", options: .regularExpression)
                != nil,
            receipt.outcome == "approved", receipt.publicDiscovery,
            receipt.ownedBrowserClosed, receipt.activationPolicyRestored, !receipt.managedViewReady
        else { throw HostedManagedApprovalError.invalidRoute }
        return receipt
    }
}
