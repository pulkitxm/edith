import CoreFoundation
import Darwin
import Foundation

struct HostedManagedViewRoute: Codable, Equatable {
    let schema: Int
    let extensionID: String
    let location: String
    let section: String
    let version: String
    let hostABI: String
    let sourceFingerprint: String
    let packageSHA256: String
    let sourceCommit: String
    let hostIdentifier: String
    let directory: String
    let factoryOverlay: Bool

    static let owners: Set<String> = [
        "keepAwake", "focusDim", "windowSweaters", "micMute", "keystrokeHighlight", "presenter",
        "colorPicker", "systemStats", "emoji", "jev", "audioMixer", "music", "homebrew", "calendar",
        "system", "timeLapse", "cleaner", "appMaintenance", "plugins", "blitztree", "notchShelf",
        "clipboard", "docs", "latex", "companion", "terminal", "usage", "bifrost", "lidAwake",
        "attention", "machines", "downloads", "seoAudit", "virtualCamera", "codeStats", "studio",
        "herdr", "quinjet", "database", "socialManager",
    ]
    static let settingsOwners: Set<String> = [
        "keepAwake", "focusDim", "windowSweaters", "micMute", "keystrokeHighlight", "presenter",
        "colorPicker", "systemStats", "emoji", "jev", "notchShelf", "bifrost", "lidAwake",
    ]

    func validate(
        extensionID id: String, version selectedVersion: String, hostABI abi: String,
        packageSHA256 selectedSHA: String
    ) throws {
        guard schema == 1, Self.owners.contains(extensionID), id == extensionID,
            version == selectedVersion, hostABI == abi, packageSHA256 == selectedSHA,
            location == (Self.settingsOwners.contains(id) ? "settings" : "main"),
            section == (id == "notchShelf" ? "extension" : id),
            factoryOverlay == ["plugins", "studio"].contains(id),
            !version.isEmpty, version.utf8.count <= 80, !hostABI.isEmpty, hostABI.utf8.count <= 100,
            packageSHA256.count == 64,
            packageSHA256.allSatisfy({ $0.isASCII && "0123456789abcdef".contains($0) }),
            sourceFingerprint.count == 64,
            sourceFingerprint.allSatisfy({ $0.isASCII && "0123456789abcdef".contains($0) }),
            sourceCommit.count == 40,
            sourceCommit.allSatisfy({ $0.isASCII && "0123456789abcdef".contains($0) })
        else { throw CocoaError(.fileReadCorruptFile) }
        let prefix = "com.pulkit.edith.tests." + (id == "calendar" ? "remote-" : "worker-")
        guard hostIdentifier.hasPrefix(prefix),
            UUID(uuidString: String(hostIdentifier.dropFirst(prefix.count))) != nil
        else { throw CocoaError(.fileReadCorruptFile) }
    }

    static func load(directory: URL) throws -> Self {
        guard directory.isFileURL, directory.path == directory.standardizedFileURL.path,
            directory.path == directory.resolvingSymlinksInPath().path
        else { throw CocoaError(.fileReadCorruptFile) }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        defer { close(descriptor) }
        var root = stat()
        guard fstat(descriptor, &root) == 0, root.st_uid == getuid(), root.st_mode & 0o7777 == 0o700
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let file = openat(descriptor, "managed-route.json", O_RDONLY | O_NOFOLLOW)
        guard file >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(file, &before) == 0, before.st_uid == getuid(),
            before.st_mode & S_IFMT == S_IFREG,
            before.st_mode & 0o7777 == 0o600, before.st_nlink == 1,
            before.st_size > 0, before.st_size <= 16_384,
            let bytes = try handle.read(upToCount: 16_385), bytes.count == before.st_size,
            let values = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(values.keys)
                == Set([
                    "schema", "extensionID", "location", "section", "version", "hostABI",
                    "sourceFingerprint", "packageSHA256", "sourceCommit", "hostIdentifier",
                    "directory",
                    "factoryOverlay",
                ]),
            let schema = values["schema"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
            let overlay = values["factoryOverlay"] as? NSNumber,
            CFGetTypeID(overlay) == CFBooleanGetTypeID()
        else { throw CocoaError(.fileReadCorruptFile) }
        var after = stat()
        guard fstat(file, &after) == 0, before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        else { throw CocoaError(.fileReadCorruptFile) }
        let route = try JSONDecoder().decode(Self.self, from: bytes)
        try route.validate(
            extensionID: route.extensionID, version: route.version,
            hostABI: route.hostABI, packageSHA256: route.packageSHA256)
        guard route.directory == directory.path else { throw CocoaError(.fileReadCorruptFile) }
        return route
    }
}
