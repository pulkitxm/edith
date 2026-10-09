import Darwin
import ExtensionMarketplace
import Foundation

public struct HostPrivilegedAdmission {
    public let root: URL
    private let ownerUID: uid_t
    private let verify: (URL) throws -> Void

    public init(root: URL, ownerUID: uid_t = 0, verify: @escaping (URL) throws -> Void) {
        self.root = root; self.ownerUID = ownerUID; self.verify = verify
    }

    public func admit(source: URL, owner: String, version: String) throws -> URL {
        guard Self.valid(owner), Self.valid(version), source.isFileURL else {
            throw MarketplaceError.invalidBundle
        }
        try verify(source)
        try validateIdentity(source, owner: owner, version: version)
        try validateTree(source, immutable: false)
        try ensureRoot()
        let candidate = root.appendingPathComponent(owner + "-" + UUID().uuidString)
            .appendingPathExtension("bundle")
        do {
            try FileManager.default.copyItem(at: source, to: candidate)
            try validateTree(candidate, immutable: false)
            try sealTree(candidate)
            try verify(candidate)
            try validateIdentity(candidate, owner: owner, version: version)
            try validateTree(candidate, immutable: true)
            return candidate
        } catch {
            try? FileManager.default.removeItem(at: candidate)
            throw error
        }
    }

    public func remove(_ bundle: URL) throws {
        guard bundle.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
        else { throw MarketplaceError.invalidBundle }
        try validateTree(bundle, immutable: true)
        try FileManager.default.removeItem(at: bundle)
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        var cursor = root.standardizedFileURL
        while cursor.path != "/" {
            var value = stat()
            guard lstat(cursor.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
                value.st_uid == ownerUID, value.st_mode & 0o022 == 0
            else { throw MarketplaceError.invalidSignature }
            if ownerUID != 0,
                cursor == FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            {
                break
            }
            cursor.deleteLastPathComponent()
        }
    }

    private func validateIdentity(_ url: URL, owner: String, version: String) throws {
        guard let bundle = Bundle(url: url),
            bundle.bundleIdentifier == "com.pulkit.edith.extensions.\(owner).privileged",
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
            bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String
                == HostContract.compatibility
        else { throw MarketplaceError.invalidBundle }
    }

    private func paths(_ url: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil, options: [])
        else { throw MarketplaceError.invalidBundle }
        var result = [url]
        for case let next as URL in enumerator {
            guard result.count < 10_000 else { throw MarketplaceError.invalidBundle }
            result.append(next)
        }
        return result
    }

    private func validateTree(_ url: URL, immutable: Bool) throws {
        var bytes: Int64 = 0
        for path in try paths(url) {
            var value = stat()
            guard lstat(path.path, &value) == 0,
                [S_IFREG, S_IFDIR].contains(value.st_mode & S_IFMT),
                value.st_nlink == 1 || value.st_mode & S_IFMT == S_IFDIR
            else { throw MarketplaceError.invalidBundle }
            bytes += Int64(value.st_size)
            guard bytes <= 256 * 1_024 * 1_024 else { throw MarketplaceError.invalidBundle }
            if immutable, value.st_uid != ownerUID || value.st_mode & 0o022 != 0 {
                throw MarketplaceError.invalidSignature
            }
        }
    }

    private func sealTree(_ url: URL) throws {
        for path in try paths(url) {
            var value = stat()
            guard lstat(path.path, &value) == 0 else { throw MarketplaceError.invalidBundle }
            guard chown(path.path, ownerUID, ownerUID == 0 ? 0 : getgid()) == 0,
                chmod(
                    path.path,
                    value.st_mode & S_IFMT == S_IFDIR || value.st_mode & 0o111 != 0 ? 0o755 : 0o644)
                    == 0
            else { throw MarketplaceError.invalidSignature }
        }
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 96
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            } && value != "." && value != ".."
    }
}
