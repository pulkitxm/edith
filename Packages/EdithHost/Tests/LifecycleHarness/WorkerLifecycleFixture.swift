import CoreFoundation
import Darwin
import Foundation

enum WorkerLifecycleFixtureError: Error {
    case unsupported, identity, path, marker, package
}

struct WorkerLifecycleFixture {
    static let inertIDs: Set<String> = [
        "focusDim", "windowSweaters", "micMute", "keystrokeHighlight", "presenter",
        "colorPicker", "systemStats", "emoji", "music", "plugins", "studio",
        "keepAwake", "notchShelf",
    ]
    static let supportedIDs: Set<String> = [
        "focusDim", "windowSweaters", "micMute", "keystrokeHighlight", "presenter", "colorPicker",
        "systemStats", "emoji", "music", "plugins", "studio",
        "keepAwake", "audioMixer", "homebrew", "calendar", "jev", "system", "timeLapse",
        "cleaner", "appMaintenance", "blitztree", "notchShelf", "clipboard", "docs",
        "latex", "companion", "terminal", "usage", "bifrost", "lidAwake", "attention",
        "machines", "downloads", "seoAudit", "virtualCamera", "codeStats", "herdr",
        "quinjet", "database",
    ]

    static func requireSupported(_ id: String) throws {
        guard supportedIDs.contains(id) else {
            throw WorkerLifecycleFixtureError.unsupported
        }
    }

    struct Selection: Equatable {
        let extensionID: String
        let dataDirectory: URL
        let roleDirectory: URL
        let version: String
        let hostABI: String
    }

    let root: URL
    let hostIdentifier: String

    init(root: URL, hostIdentifier: String) throws {
        let prefix = "com.pulkit.edith.tests.worker-"
        guard hostIdentifier.hasPrefix(prefix),
            UUID(uuidString: String(hostIdentifier.dropFirst(prefix.count))) != nil
        else { throw WorkerLifecycleFixtureError.identity }
        try Self.validateDirectory(root, mode: 0o700)
        guard root.path != "/", root != FileManager.default.homeDirectoryForCurrentUser else {
            throw WorkerLifecycleFixtureError.path
        }
        self.root = root
        self.hostIdentifier = hostIdentifier
    }

    func home(for id: String) throws -> URL {
        try Self.requireSupported(id)
        guard Self.validComponent(id) else { throw WorkerLifecycleFixtureError.identity }
        let home = root.appendingPathComponent(id + "-home", isDirectory: true)
        if !FileManager.default.fileExists(atPath: home.path) {
            try FileManager.default.createDirectory(
                at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        }
        try Self.validateDirectory(home, mode: 0o700)
        return home
    }

    func issue(_ selection: Selection, hostApp: URL, defaultsSuite: String) throws {
        try Task.checkCancellation()
        try validate(selection, hostApp: hostApp, defaultsSuite: defaultsSuite)
        let home = try home(for: selection.extensionID)
        let directory = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw WorkerLifecycleFixtureError.path }
        defer { Darwin.close(directory) }
        try Self.validateDescriptor(directory, directory: true, mode: 0o700)
        if let existing = try readMarker(directory) {
            try validateValues(existing, selection: selection, exactVersion: false)
        }
        let bytes = try JSONSerialization.data(
            withJSONObject: values(selection), options: [.sortedKeys])
        guard !bytes.isEmpty, bytes.count <= 16_384 else {
            throw WorkerLifecycleFixtureError.marker
        }
        let name = UUID().uuidString + ".pending"
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw WorkerLifecycleFixtureError.marker }
        defer {
            Darwin.close(descriptor)
            unlinkat(directory, name, 0)
        }
        try Self.validateDescriptor(descriptor, directory: false, mode: 0o600)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WorkerLifecycleFixtureError.marker }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw WorkerLifecycleFixtureError.marker }
        try Task.checkCancellation()
        try Self.validateDirectory(root, mode: 0o700)
        try Self.validateDirectory(home, mode: 0o700)
        guard renameat(directory, name, directory, "worker-fixture.json") == 0 else {
            throw WorkerLifecycleFixtureError.marker
        }
        do {
            try Task.checkCancellation()
            try validateExact(selection, hostApp: hostApp, defaultsSuite: defaultsSuite)
        } catch {
            var created = stat()
            var published = stat()
            if fstat(descriptor, &created) == 0,
                fstatat(directory, "worker-fixture.json", &published, AT_SYMLINK_NOFOLLOW) == 0,
                created.st_dev == published.st_dev, created.st_ino == published.st_ino
            {
                unlinkat(directory, "worker-fixture.json", 0)
            }
            throw error
        }
    }

    func validateExact(_ selection: Selection, hostApp: URL, defaultsSuite: String) throws {
        try validate(selection, hostApp: hostApp, defaultsSuite: defaultsSuite)
        let home = try home(for: selection.extensionID)
        let directory = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw WorkerLifecycleFixtureError.path }
        defer { Darwin.close(directory) }
        try Self.validateDescriptor(directory, directory: true, mode: 0o700)
        guard let values = try readMarker(directory) else {
            throw WorkerLifecycleFixtureError.marker
        }
        try validateValues(values, selection: selection, exactVersion: true)
    }

    func remove(_ selection: Selection) throws {
        try Self.validateDirectory(root, mode: 0o700)
        let home = try home(for: selection.extensionID)
        let directory = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw WorkerLifecycleFixtureError.path }
        defer { Darwin.close(directory) }
        try Self.validateDescriptor(directory, directory: true, mode: 0o700)
        guard let values = try readMarker(directory) else { return }
        try validateValues(values, selection: selection, exactVersion: true)
        guard unlinkat(directory, "worker-fixture.json", 0) == 0 else {
            throw WorkerLifecycleFixtureError.marker
        }
    }

    private func validate(_ selection: Selection, hostApp: URL, defaultsSuite: String) throws {
        try Self.requireSupported(selection.extensionID)
        if Self.inertIDs.contains(selection.extensionID) {
            let role =
                ["music", "plugins", "studio"].contains(selection.extensionID) ? "app" : "helper"
            guard selection.roleDirectory.lastPathComponent == role + ".bundle" else {
                throw WorkerLifecycleFixtureError.package
            }
        }
        guard ["app.bundle", "helper.bundle"].contains(selection.roleDirectory.lastPathComponent),
            Self.validComponent(selection.extensionID), Self.validComponent(selection.version),
            Self.validComponent(selection.hostABI),
            defaultsSuite == hostIdentifier + ".extensions." + selection.extensionID,
            hostApp.path == root.appendingPathComponent("Fixture.app", isDirectory: true).path
        else { throw WorkerLifecycleFixtureError.identity }
        let slot = String(hostIdentifier.dropFirst("com.pulkit.edith.tests.".count))
        let identityRoot = root.appendingPathComponent("Edith Tests").appendingPathComponent(slot)
        guard
            selection.dataDirectory.path
                == identityRoot.appendingPathComponent("Data")
                .appendingPathComponent(selection.extensionID).path,
            selection.roleDirectory.path
                == roleDirectory(selection, identityRoot: identityRoot).path
        else { throw WorkerLifecycleFixtureError.package }
        for path in [hostApp, selection.dataDirectory, selection.roleDirectory] {
            guard path.path.hasPrefix(root.path + "/") else {
                throw WorkerLifecycleFixtureError.path
            }
            var current = path
            while current.path != root.path {
                try Self.validateDirectory(current)
                current.deleteLastPathComponent()
            }
        }
        try Self.validateDirectory(root, mode: 0o700)
    }

    private func roleDirectory(_ selection: Selection, identityRoot: URL) -> URL {
        identityRoot.appendingPathComponent("Extensions/" + selection.extensionID)
            .appendingPathComponent(selection.hostABI).appendingPathComponent("arm64")
            .appendingPathComponent(selection.version).appendingPathComponent(selection.extensionID)
            .appendingPathComponent(
                "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload"
            )
            .appendingPathComponent(selection.extensionID)
            .appendingPathComponent(selection.roleDirectory.lastPathComponent)
    }

    private func values(_ selection: Selection) -> [String: Any] {
        [
            "schema": 1, "hostIdentifier": hostIdentifier, "extensionID": selection.extensionID,
            "dataDirectory": selection.dataDirectory.path,
            "roleDirectory": selection.roleDirectory.path,
            "version": selection.version, "hostABI": selection.hostABI,
        ]
    }

    private func validateValues(_ values: [String: Any], selection: Selection, exactVersion: Bool)
        throws
    {
        guard Set(values.keys) == Set(self.values(selection).keys),
            let schema = values["schema"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
            values["hostIdentifier"] as? String == hostIdentifier,
            values["extensionID"] as? String == selection.extensionID,
            values["dataDirectory"] as? String == selection.dataDirectory.path,
            values["hostABI"] as? String == selection.hostABI,
            let version = values["version"] as? String, Self.validComponent(version),
            let role = values["roleDirectory"] as? String,
            ["app.bundle", "helper.bundle"].contains(selection.roleDirectory.lastPathComponent)
        else { throw WorkerLifecycleFixtureError.marker }
        let previous = Selection(
            extensionID: selection.extensionID, dataDirectory: selection.dataDirectory,
            roleDirectory: selection.roleDirectory, version: version, hostABI: selection.hostABI)
        let slot = String(hostIdentifier.dropFirst("com.pulkit.edith.tests.".count))
        guard
            role
                == roleDirectory(
                    previous,
                    identityRoot: root.appendingPathComponent("Edith Tests")
                        .appendingPathComponent(slot)
                ).path,
            !exactVersion || version == selection.version
        else { throw WorkerLifecycleFixtureError.marker }
    }

    private func readMarker(_ directory: Int32) throws -> [String: Any]? {
        let descriptor = openat(
            directory, "worker-fixture.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 && errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw WorkerLifecycleFixtureError.marker }
        defer { Darwin.close(descriptor) }
        try Self.validateDescriptor(descriptor, directory: false, mode: 0o600)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_size > 0, metadata.st_size <= 16_384
        else {
            throw WorkerLifecycleFixtureError.marker
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: 16_385) ?? Data()
        guard bytes.count == Int(metadata.st_size),
            let values = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { throw WorkerLifecycleFixtureError.marker }
        return values
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value != "." && value != ".."
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".")
            }
    }

    private static func validateDirectory(_ path: URL, mode: mode_t? = nil) throws {
        guard path.isFileURL, path.path == path.standardizedFileURL.path,
            path.path == path.resolvingSymlinksInPath().path
        else { throw WorkerLifecycleFixtureError.path }
        let descriptor = open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WorkerLifecycleFixtureError.path }
        defer { Darwin.close(descriptor) }
        try validateDescriptor(descriptor, directory: true, mode: mode)
    }

    private static func validateDescriptor(_ descriptor: Int32, directory: Bool, mode: mode_t?)
        throws
    {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
            metadata.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
            metadata.st_mode & 0o022 == 0,
            directory || metadata.st_nlink == 1,
            mode == nil || metadata.st_mode & 0o7777 == mode
        else { throw WorkerLifecycleFixtureError.path }
    }
}
