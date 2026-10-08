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

    public func installedPackages() throws -> [ExtensionPackage] {
        let state = root.appendingPathComponent("installed.json")
        guard FileManager.default.fileExists(atPath: state.path) else { return [] }
        let packages = try JSONDecoder().decode(
            [ExtensionPackage].self, from: Data(contentsOf: state))
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

    public func installedPackage(id: String, hostABI: String, architecture: String) throws
        -> ExtensionPackage?
    {
        try installedPackages().filter {
            $0.id == id && $0.hostABI == hostABI && $0.architecture == architecture
        }.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    public func commit(_ packages: [ExtensionPackage]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(packages).write(
            to: root.appendingPathComponent("installed.json"), options: .atomic)
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
        try commit(packages.filter { $0.id != id })
        for package in removed { try FileManager.default.removeItem(at: directory(for: package)) }
        return !removed.isEmpty
    }

    public func pendingRemovals() throws -> Set<String> {
        let file = root.appendingPathComponent("pending-removals.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let ids = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file))
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
        try JSONEncoder().encode(ids.sorted()).write(to: file, options: .atomic)
    }

    public func leaseURL(for package: ExtensionPackage) -> URL {
        root.appendingPathComponent(".leases").appendingPathComponent(
            "\(package.id)-\(package.hostABI)-\(package.architecture)-\(package.version).lock")
    }

    public func lease(_ package: ExtensionPackage) throws -> PackageFileLock {
        try PackageFileLock(url: leaseURL(for: package), exclusive: false)
    }

    public func prune() throws {
        let operation = try PackageFileLock(
            url: root.appendingPathComponent(".operation.lock"), exclusive: true)
        defer { operation.close() }
        let packages = try installedPackages()
        let groups = Dictionary(grouping: packages) { "\($0.id)/\($0.hostABI)/\($0.architecture)" }
        var retained = packages
        for group in groups.values {
            let ordered = group.sorted {
                $0.version.compare($1.version, options: .numeric) == .orderedDescending
            }
            for package in ordered.dropFirst(2) {
                guard let lease = try? PackageFileLock(url: leaseURL(for: package), exclusive: true)
                else { continue }
                defer { lease.close() }
                let directory = directory(for: package)
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                retained.removeAll { $0 == package }
            }
        }
        try commit(retained)
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
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw MarketplaceError.packageBusy }
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
