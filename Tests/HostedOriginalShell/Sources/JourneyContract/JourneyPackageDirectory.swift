import Darwin
import Foundation

public struct JourneyPackageDirectory: Equatable, Sendable {
    public let version: String
    public let relativePath: String

    public init(id: String, hostABI: String, architecture: String, version: String) throws {
        guard id == "calendar", hostABI == "edith-host-2", architecture == "arm64",
            ["1.0.0", "1.1.0"].contains(version)
        else { throw JourneyContractError.invalidMetadata }
        self.version = version
        relativePath = "Extensions/\(id)/\(hostABI)/\(architecture)/\(version)"
    }

    public func isPresent(in root: URL) throws -> Bool {
        guard root.isFileURL, root.path == root.standardizedFileURL.path,
            root.path == root.resolvingSymlinksInPath().standardizedFileURL.path
        else { throw JourneyContractError.invalidPaths }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw JourneyContractError.invalidPaths }
        var descriptors = [descriptor]
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        let original = try Self.ownedDirectory(descriptor)
        func validateRoot() throws {
            var current = stat()
            guard lstat(root.path, &current) == 0,
                current.st_dev == original.st_dev, current.st_ino == original.st_ino,
                current.st_uid == original.st_uid, current.st_mode == original.st_mode,
                root.path == root.resolvingSymlinksInPath().standardizedFileURL.path
            else { throw JourneyContractError.invalidPaths }
        }
        for component in relativePath.split(separator: "/") {
            let child = openat(
                descriptors.last!, String(component),
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if child < 0 {
                guard errno == ENOENT else { throw JourneyContractError.invalidPaths }
                try validateRoot()
                return false
            }
            descriptors.append(child)
            _ = try Self.ownedDirectory(child)
        }
        try validateRoot()
        return true
    }

    private static func ownedDirectory(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_uid == geteuid(),
            value.st_mode & S_IFMT == S_IFDIR, value.st_mode & 0o022 == 0
        else { throw JourneyContractError.invalidPaths }
        return value
    }
}
