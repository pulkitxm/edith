import Darwin
import EdithCore
import Foundation

public enum DatabaseBrokerPathsError: Error, Equatable, Sendable {
    case invalidDataDirectory
    case invalidRuntimeDirectory
    case unsafeDataDirectory
    case unsafeRuntimeDirectory
    case unsafeMetadataFile
    case unavailable
}

enum DatabaseBrokerPathsPreparationStage: Sendable {
    case dataDirectoryOpened
    case metadataFileOpened
    case runtimeDirectoryOpened
}

public struct DatabaseBrokerPaths: Equatable, Sendable {
    public static let databaseDirectoryName = "database"
    public static let metadataFilename = "metadata.sqlite3"
    public static let ownerLockFilename = "owner.lock"
    public static let socketFilename = "broker.sock"

    public let dataDirectory: URL
    public let metadataFile: URL
    public let runtimeDirectory: URL
    public let ownerLockFile: URL
    public let socketFile: URL

    public init(directories: AppDirectories = .current) {
        self.init(
            dataDirectory: directories.data.appendingPathComponent(
                Self.databaseDirectoryName,
                isDirectory: true),
            runtimeDirectory: directories.runtime.appendingPathComponent(
                Self.databaseDirectoryName,
                isDirectory: true))
    }

    init(dataDirectory: URL, runtimeDirectory: URL) {
        self.dataDirectory = dataDirectory
        metadataFile = dataDirectory.appendingPathComponent(Self.metadataFilename)
        self.runtimeDirectory = runtimeDirectory
        ownerLockFile = runtimeDirectory.appendingPathComponent(Self.ownerLockFilename)
        socketFile = runtimeDirectory.appendingPathComponent(Self.socketFilename)
    }

    public func prepare() throws {
        try prepare { _ in }
    }

    func prepare(
        observe: (DatabaseBrokerPathsPreparationStage) throws -> Void
    ) throws {
        let data = try Self.openDirectory(
            dataDirectory,
            invalidError: .invalidDataDirectory,
            unsafeError: .unsafeDataDirectory)
        defer { Self.closeDirectory(data) }
        try observe(.dataDirectoryOpened)

        let metadataDescriptor = try Self.openMetadataFile(
            directoryDescriptor: data.descriptor)
        defer { close(metadataDescriptor) }
        try observe(.metadataFileOpened)

        let runtime = try Self.openDirectory(
            runtimeDirectory,
            invalidError: .invalidRuntimeDirectory,
            unsafeError: .unsafeRuntimeDirectory)
        defer { Self.closeDirectory(runtime) }
        try observe(.runtimeDirectoryOpened)

        guard Self.pathStillReferencesDirectory(data) else {
            throw DatabaseBrokerPathsError.unsafeDataDirectory
        }
        guard
            Self.pathReferencesMetadataFile(
                directoryDescriptor: data.descriptor,
                descriptor: metadataDescriptor)
        else {
            throw DatabaseBrokerPathsError.unsafeMetadataFile
        }
        guard Self.pathStillReferencesDirectory(runtime) else {
            throw DatabaseBrokerPathsError.unsafeRuntimeDirectory
        }
    }

    private struct OpenDirectory {
        let components: [String]
        let descriptors: [Int32]

        var descriptor: Int32 {
            descriptors[descriptors.count - 1]
        }
    }

    private static func openDirectory(
        _ url: URL,
        invalidError: DatabaseBrokerPathsError,
        unsafeError: DatabaseBrokerPathsError
    ) throws -> OpenDirectory {
        guard let components = directoryComponents(url) else {
            throw invalidError
        }
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        let rootDescriptor = open("/", flags)
        guard rootDescriptor >= 0 else {
            throw DatabaseBrokerPathsError.unavailable
        }
        var descriptors = [rootDescriptor]
        do {
            for (index, component) in components.enumerated() {
                let isLeaf = index == components.count - 1
                var created = false
                if isLeaf {
                    let creationResult = mkdirat(
                        descriptors[descriptors.count - 1],
                        component,
                        mode_t(0o700))
                    created = creationResult == 0
                    if !created, errno != EEXIST {
                        if errno == ELOOP || errno == ENOTDIR {
                            throw unsafeError
                        }
                        throw DatabaseBrokerPathsError.unavailable
                    }
                }
                let parentDescriptor = descriptors[descriptors.count - 1]
                let descriptor = openat(parentDescriptor, component, flags)
                guard descriptor >= 0 else {
                    if errno == ELOOP || errno == ENOTDIR {
                        throw unsafeError
                    }
                    if isLeaf, errno == ENOENT {
                        throw unsafeError
                    }
                    throw DatabaseBrokerPathsError.unavailable
                }
                descriptors.append(descriptor)

                var pathMetadata = stat()
                var descriptorMetadata = stat()
                guard
                    fstatat(
                        parentDescriptor,
                        component,
                        &pathMetadata,
                        AT_SYMLINK_NOFOLLOW) == 0,
                    fstat(descriptor, &descriptorMetadata) == 0,
                    pathMetadata.st_mode & S_IFMT == S_IFDIR,
                    descriptorMetadata.st_mode & S_IFMT == S_IFDIR,
                    sameFile(pathMetadata, descriptorMetadata)
                else {
                    throw unsafeError
                }
                guard
                    !isLeaf
                        || safeDirectoryMetadata(
                            descriptorMetadata,
                            requireMode: !created)
                else {
                    throw unsafeError
                }
                if created {
                    guard fchmod(descriptor, mode_t(0o700)) == 0 else {
                        throw DatabaseBrokerPathsError.unavailable
                    }
                    guard
                        fstat(descriptor, &descriptorMetadata) == 0,
                        safeDirectoryMetadata(descriptorMetadata, requireMode: true)
                    else {
                        throw unsafeError
                    }
                }
            }

            let directory = OpenDirectory(
                components: components,
                descriptors: descriptors)
            guard pathStillReferencesDirectory(directory) else {
                throw unsafeError
            }
            return directory
        } catch {
            for descriptor in descriptors.reversed() {
                close(descriptor)
            }
            throw error
        }
    }

    private static func closeDirectory(_ directory: OpenDirectory) {
        for descriptor in directory.descriptors.reversed() {
            close(descriptor)
        }
    }

    private static func openMetadataFile(
        directoryDescriptor: Int32
    ) throws -> Int32 {
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        var descriptor = openat(
            directoryDescriptor,
            metadataFilename,
            flags | O_CREAT | O_EXCL,
            mode_t(0o600))
        let created = descriptor >= 0
        if descriptor < 0 {
            guard errno == EEXIST else {
                if errno == ELOOP || errno == EISDIR || errno == ENOTDIR {
                    throw DatabaseBrokerPathsError.unsafeMetadataFile
                }
                throw DatabaseBrokerPathsError.unavailable
            }
            descriptor = openat(directoryDescriptor, metadataFilename, flags)
            guard descriptor >= 0 else {
                throw DatabaseBrokerPathsError.unsafeMetadataFile
            }
        }
        do {
            guard validMetadataFile(descriptor, requireMode: !created) else {
                throw DatabaseBrokerPathsError.unsafeMetadataFile
            }
            if created {
                guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                    throw DatabaseBrokerPathsError.unavailable
                }
                guard validMetadataFile(descriptor) else {
                    throw DatabaseBrokerPathsError.unsafeMetadataFile
                }
            }
            guard
                pathReferencesMetadataFile(
                    directoryDescriptor: directoryDescriptor,
                    descriptor: descriptor)
            else {
                throw DatabaseBrokerPathsError.unsafeMetadataFile
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func directoryComponents(_ url: URL) -> [String]? {
        guard
            url.isFileURL,
            url.host == nil || url.host?.isEmpty == true || url.host == "localhost",
            url.query == nil,
            url.fragment == nil
        else {
            return nil
        }
        let path = url.path
        guard path.hasPrefix("/"), !path.utf8.isEmpty, !path.utf8.contains(0) else {
            return nil
        }
        let components = path.split(separator: "/").map(String.init)
        guard
            !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            return nil
        }
        return components
    }

    private static func safeDirectoryMetadata(
        _ metadata: stat,
        requireMode: Bool
    ) -> Bool {
        guard
            metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == geteuid()
        else {
            return false
        }
        return !requireMode || metadata.st_mode & mode_t(0o7777) == mode_t(0o700)
    }

    private static func validMetadataFile(
        _ descriptor: Int32,
        requireMode: Bool = true
    ) -> Bool {
        var metadata = stat()
        guard
            fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == geteuid(),
            metadata.st_nlink == 1
        else {
            return false
        }
        return !requireMode || metadata.st_mode & mode_t(0o7777) == mode_t(0o600)
    }

    private static func pathReferencesMetadataFile(
        directoryDescriptor: Int32,
        descriptor: Int32
    ) -> Bool {
        var pathMetadata = stat()
        var descriptorMetadata = stat()
        return fstatat(
            directoryDescriptor,
            metadataFilename,
            &pathMetadata,
            AT_SYMLINK_NOFOLLOW) == 0
            && fstat(descriptor, &descriptorMetadata) == 0
            && descriptorMetadata.st_mode & S_IFMT == S_IFREG
            && descriptorMetadata.st_uid == geteuid()
            && descriptorMetadata.st_nlink == 1
            && descriptorMetadata.st_mode & mode_t(0o7777) == mode_t(0o600)
            && sameFile(pathMetadata, descriptorMetadata)
    }

    private static func pathStillReferencesDirectory(
        _ directory: OpenDirectory
    ) -> Bool {
        guard directory.descriptors.count == directory.components.count + 1 else {
            return false
        }
        for index in directory.components.indices {
            var pathMetadata = stat()
            var descriptorMetadata = stat()
            guard
                fstatat(
                    directory.descriptors[index],
                    directory.components[index],
                    &pathMetadata,
                    AT_SYMLINK_NOFOLLOW) == 0,
                fstat(directory.descriptors[index + 1], &descriptorMetadata) == 0,
                pathMetadata.st_mode & S_IFMT == S_IFDIR,
                descriptorMetadata.st_mode & S_IFMT == S_IFDIR,
                sameFile(pathMetadata, descriptorMetadata)
            else {
                return false
            }
        }
        var leafMetadata = stat()
        return fstat(directory.descriptor, &leafMetadata) == 0
            && safeDirectoryMetadata(leafMetadata, requireMode: true)
    }

    private static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }
}
