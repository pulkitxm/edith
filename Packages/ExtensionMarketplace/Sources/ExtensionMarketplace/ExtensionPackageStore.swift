import CryptoKit
import Darwin
import Foundation

public struct ExtensionPackageStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func directory(for package: ExtensionPackage) -> URL {
        root.appendingPathComponent(package.id).appendingPathComponent(package.hostABI)
            .appendingPathComponent(package.architecture).appendingPathComponent(package.version)
    }

    public func payloadDirectory(for package: ExtensionPackage) -> URL {
        let payload = directory(for: package).appendingPathComponent(package.id)
        let carrier = payload.appendingPathComponent("ExtensionCarrier.app")
        guard FileManager.default.fileExists(atPath: carrier.path) else { return payload }
        return carrier.appendingPathComponent(
            "Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload"
        ).appendingPathComponent(package.id)
    }

    public func roleBundle(
        for package: ExtensionPackage, role: ExtensionBundleRuntime.Role
    ) -> URL {
        payloadDirectory(for: package).appendingPathComponent("\(role.rawValue).bundle")
    }

    public func installedPackages() throws -> [ExtensionPackage] {
        guard let data = try PackageDirectory(root, create: true).read("installed.json") else {
            return []
        }
        let packages = try JSONDecoder().decode([ExtensionPackage].self, from: data)
        guard
            packages.allSatisfy({
                ExtensionPackage.validComponent($0.id)
                    && ExtensionPackage.validComponent($0.version)
                    && ExtensionPackage.validComponent($0.hostABI)
                    && ["arm64", "x86_64"].contains($0.architecture)
            })
        else { throw MarketplaceError.invalidCatalog }
        return packages
    }

    public func installedPackage(
        id: String, hostABI: String, architecture: String, version: String? = nil,
        systemVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) throws -> ExtensionPackage? {
        let compatible = try installedPackages().filter {
            $0.id == id && (version == nil || $0.version == version)
                && $0.isCompatible(
                    hostABI: hostABI, architecture: architecture, systemVersion: systemVersion)
        }
        if let selected = try selections().first(where: { compatible.contains($0) }) {
            return selected
        }
        return compatible.max {
            $0.version.compare($1.version, options: .numeric) == .orderedAscending
        }
    }

    public func select(_ package: ExtensionPackage) throws {
        let operation = try PackageFileLock(
            url: root.appendingPathComponent(".operation.lock"), exclusive: true)
        defer { operation.close() }
        guard try installedPackages().contains(package) else {
            throw MarketplaceError.packageNotInstalled
        }
        var selected = try selections().filter {
            $0.id != package.id || $0.hostABI != package.hostABI
                || $0.architecture != package.architecture
        }
        selected.append(package)
        try saveSelections(selected)
    }

    private func selections() throws -> [ExtensionPackage] {
        guard let data = try PackageDirectory(root, create: true).read("selected-packages.json")
        else { return [] }
        return try JSONDecoder().decode([ExtensionPackage].self, from: data)
    }

    private func saveSelections(_ packages: [ExtensionPackage]) throws {
        try PackageDirectory(root, create: true).write(
            JSONEncoder().encode(packages), name: "selected-packages.json")
    }

    public func commit(_ packages: [ExtensionPackage]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PackageDirectory(root, create: true).write(
            encoder.encode(packages), name: "installed.json")
    }

    public func remove(id: String) throws -> Bool {
        guard ExtensionPackage.validComponent(id) else { throw MarketplaceError.invalidCatalog }
        let operation = try PackageFileLock(
            url: root.appendingPathComponent(".operation.lock"), exclusive: true)
        defer { operation.close() }
        let packages = try installedPackages()
        guard !packages.contains(where: { $0.id != id && $0.dependencies.contains(id) }) else {
            throw MarketplaceError.dependencyInUse
        }
        let removed = packages.filter { $0.id == id }
        let leases = try removed.map { package in
            try PackageFileLock(url: leaseURL(for: package), exclusive: true)
        }
        defer { leases.forEach { $0.close() } }
        let authority = try PackageDirectory(root, create: true)
        for package in removed { try authority.remove(package) }
        try saveSelections(selections().filter { $0.id != id })
        try commit(packages.filter { $0.id != id })
        return !removed.isEmpty
    }

    public func pendingRemovals() throws -> Set<String> {
        guard let data = try PackageDirectory(root, create: true).read("pending-removals.json")
        else { return [] }
        let ids = try JSONDecoder().decode(Set<String>.self, from: data)
        guard ids.allSatisfy(ExtensionPackage.validComponent) else {
            throw MarketplaceError.invalidCatalog
        }
        return ids
    }

    public func requestRemoval(id: String) throws -> Bool {
        do {
            _ = try remove(id: id)
            try updatePendingRemoval(id: id, pending: false)
            return true
        } catch MarketplaceError.packageBusy {
            guard ExtensionPackage.validComponent(id) else { throw MarketplaceError.invalidCatalog }
            try updatePendingRemoval(id: id, pending: true)
            return false
        }
    }

    public func completePendingRemovals() throws {
        for id in try pendingRemovals().sorted() {
            do {
                _ = try remove(id: id)
                try updatePendingRemoval(id: id, pending: false)
            } catch MarketplaceError.packageBusy {
                continue
            }
        }
    }

    private func updatePendingRemoval(id: String, pending: Bool) throws {
        let file = root.appendingPathComponent("pending-removals.json")
        let operation = try PackageFileLock(
            url: file.appendingPathExtension("lock"), exclusive: true)
        defer { operation.close() }
        var ids = try pendingRemovals()
        if pending { ids.insert(id) } else { ids.remove(id) }
        try PackageDirectory(root, create: true).write(
            JSONEncoder().encode(ids.sorted()), name: "pending-removals.json")
    }

    public func leaseURL(for package: ExtensionPackage) -> URL {
        root.appendingPathComponent(".leases").appendingPathComponent(
            "\(package.id)-\(package.hostABI)-\(package.architecture)-\(package.version).lock")
    }

    public func lease(_ package: ExtensionPackage) throws -> PackageFileLock {
        try PackageFileLock(url: leaseURL(for: package), exclusive: false)
    }

    public func prune(
        hostABI: String,
        systemVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) throws {
        let operation = try PackageFileLock(
            url: root.appendingPathComponent(".operation.lock"), exclusive: true)
        defer { operation.close() }
        let packages = try installedPackages()
        let selected = try selections()
        let groups = Dictionary(grouping: packages) { "\($0.id)/\($0.architecture)" }
        var retained = packages
        for group in groups.values {
            let ordered = group.sorted {
                $0.version.compare($1.version, options: .numeric) == .orderedDescending
            }
            let compatible = ordered.filter {
                $0.hostABI == hostABI && $0.minimumSystemVersion <= systemVersion
            }
            let keep =
                (compatible.isEmpty ? Array(ordered.prefix(2)) : Array(compatible.prefix(2)))
                + compatible.filter { selected.contains($0) }
            for package in ordered where !keep.contains(package) {
                let lease: PackageFileLock
                do {
                    lease = try PackageFileLock(url: leaseURL(for: package), exclusive: true)
                } catch MarketplaceError.packageBusy { continue }
                defer { lease.close() }
                try PackageDirectory(root, create: true).remove(package)
                retained.removeAll { $0 == package }
            }
        }
        try commit(retained)
        try saveSelections(selected.filter { retained.contains($0) })
    }

    public func diskBytes() -> Int64 {
        guard
            let entries = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return 0 }
        var bytes: Int64 = 0
        for case let file as URL in entries {
            guard
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { continue }
            bytes += Int64(values.fileSize ?? 0)
        }
        return bytes
    }
}

public final class PackageFileLock: @unchecked Sendable {
    private var descriptor: Int32

    public init(url: URL, exclusive: Bool) throws {
        let parent = try PackageDirectory(url.deletingLastPathComponent(), create: true)
        descriptor = openat(
            parent.descriptor, url.lastPathComponent,
            O_CREAT | O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PackageDirectory.failure() }
        do { try PackageDirectory.validate(descriptor, directory: false, owned: true) } catch {
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            throw MarketplaceError.packageBusy
        }
    }

    public func close() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { close() }
}

final class PackageDirectory {
    let descriptor: Int32

    init(_ url: URL, create: Bool) throws {
        var path = url.path
        for alias in ["var", "tmp"] {
            if path == "/\(alias)" || path.hasPrefix("/\(alias)/") {
                path = "/private" + path
                break
            }
        }
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !components.isEmpty,
            components.allSatisfy({ $0 != "." && $0 != ".." })
        else { throw MarketplaceError.invalidArchive }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw Self.failure() }
        do {
            var walked = ""
            for (index, component) in components.enumerated() {
                walked += "/" + component
                var next = openat(
                    current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(current, component, S_IRWXU) == 0 || errno == EEXIST else {
                        throw Self.failure()
                    }
                    next = openat(
                        current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw Self.failure() }
                do {
                    try Self.validate(
                        next, directory: true, owned: index == components.count - 1,
                        temporary: walked == "/private/tmp")
                } catch {
                    Darwin.close(next)
                    throw error
                }
                Darwin.close(current)
                current = next
            }
            descriptor = current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { Darwin.close(descriptor) }

    static func failure() -> Error { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    static func validate(
        _ descriptor: Int32, directory: Bool, owned: Bool, temporary: Bool = false
    ) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure() }
        let kind = info.st_mode & S_IFMT
        guard kind == (directory ? S_IFDIR : S_IFREG),
            info.st_uid == getuid() || (!owned && info.st_uid == 0),
            info.st_mode & 0o022 == 0
                || (temporary && info.st_uid == 0 && info.st_mode & S_ISVTX != 0)
        else { throw MarketplaceError.invalidArchive }
    }

    func child(_ name: String, create: Bool = false) throws -> PackageDirectory? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0")
        else { throw MarketplaceError.invalidCatalog }
        var next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0, errno == ENOENT, create {
            guard mkdirat(descriptor, name, S_IRWXU) == 0 || errno == EEXIST else {
                throw Self.failure()
            }
            next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if next < 0, errno == ENOENT { return nil }
        guard next >= 0 else { throw Self.failure() }
        do { try Self.validate(next, directory: true, owned: true) } catch {
            Darwin.close(next)
            throw error
        }
        return PackageDirectory(descriptor: next)
    }

    func parent(_ package: ExtensionPackage, create: Bool = false) throws -> PackageDirectory? {
        guard
            [package.id, package.hostABI, package.architecture, package.version]
                .allSatisfy(ExtensionPackage.validComponent)
        else {
            throw MarketplaceError.invalidCatalog
        }
        return try child(package.id, create: create)?
            .child(package.hostABI, create: create)?.child(package.architecture, create: create)
    }

    func contains(_ package: ExtensionPackage) throws -> Bool {
        try parent(package)?.child(package.version) != nil
    }

    func remove(_ package: ExtensionPackage) throws {
        try parent(package)?.removeTree(package.version)
    }

    func removeTree(_ name: String) throws {
        guard let child = try child(name) else { return }
        guard let entries = fdopendir(dup(child.descriptor)) else { throw Self.failure() }
        defer { closedir(entries) }
        while let entry = readdir(entries) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(child.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Self.failure()
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                try child.removeTree(name)
            } else {
                guard [S_IFREG, S_IFLNK].contains(info.st_mode & S_IFMT),
                    info.st_uid == getuid()
                else {
                    throw MarketplaceError.invalidArchive
                }
                guard unlinkat(child.descriptor, name, 0) == 0 else { throw Self.failure() }
            }
        }
        var opened = stat()
        var current = stat()
        guard fstat(child.descriptor, &opened) == 0,
            fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            opened.st_dev == current.st_dev, opened.st_ino == current.st_ino
        else { throw MarketplaceError.invalidArchive }
        guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw Self.failure() }
    }

    func read(_ name: String) throws -> Data? {
        let file = openat(descriptor, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw Self.failure() }
        defer { Darwin.close(file) }
        try Self.validate(file, directory: false, owned: true)
        return try FileHandle(fileDescriptor: file, closeOnDealloc: false).readToEnd() ?? Data()
    }

    func write(_ data: Data, name: String) throws {
        let temporary = ".state-\(UUID().uuidString)"
        let file = openat(
            descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard file >= 0 else { throw Self.failure() }
        defer {
            Darwin.close(file)
            unlinkat(descriptor, temporary, 0)
        }
        try FileHandle(fileDescriptor: file, closeOnDealloc: false).write(contentsOf: data)
        guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw Self.failure() }
    }

    func install(_ package: ExtensionPackage, from source: URL) throws {
        guard let parent = try parent(package, create: true) else {
            throw MarketplaceError.invalidArchive
        }
        let temporary = ".payload-\(UUID().uuidString)"
        guard let destination = try parent.child(temporary, create: true) else {
            throw MarketplaceError.invalidArchive
        }
        defer { try? parent.removeTree(temporary) }
        try destination.copy(from: PackageDirectory(source, create: false))
        try parent.removeTree(package.version)
        guard renameat(parent.descriptor, temporary, parent.descriptor, package.version) == 0 else {
            throw Self.failure()
        }
    }

    private func copy(from source: PackageDirectory) throws {
        guard let entries = fdopendir(dup(source.descriptor)) else { throw Self.failure() }
        defer { closedir(entries) }
        while let entry = readdir(entries) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(source.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Self.failure()
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                guard let original = try source.child(name),
                    let destination = try child(name, create: true)
                else { throw MarketplaceError.invalidArchive }
                try destination.copy(from: original)
            } else {
                let input = openat(
                    source.descriptor, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard input >= 0 else { throw Self.failure() }
                defer { Darwin.close(input) }
                try Self.validate(input, directory: false, owned: true)
                let output = openat(
                    descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR)
                guard output >= 0 else { throw Self.failure() }
                defer { Darwin.close(output) }
                guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                    throw Self.failure()
                }
            }
        }
        guard
            fcopyfile(
                source.descriptor, descriptor, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0
        else { throw Self.failure() }

    }
}
