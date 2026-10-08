import CryptoKit
import Foundation
import Security
import ZIPFoundation

public struct ExtensionPayloadManifest: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let hostABI: String
    public let architecture: String
    public let dependencies: [String]

    public init(package: ExtensionPackage) {
        id = package.id
        version = package.version
        hostABI = package.hostABI
        architecture = package.architecture
        dependencies = package.dependencies
    }
}

public enum ExtensionArchive {
    public static func extract(_ archive: URL, package: ExtensionPackage, to destination: URL)
        throws
    {
        let zip = try Archive(url: archive, accessMode: .read)
        var seen = Set<String>()
        var expandedBytes: UInt64 = 0
        let limit = UInt64(package.installedBytes)
        for entry in zip {
            let path = entry.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            let payloadNames = [
                "package.json", "app.bundle", "helper.bundle", "agent.bundle", "cli.bundle",
            ]
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
                parts.first == Substring(package.id),
                parts.count >= 2,
                payloadNames.contains(String(parts[1]))
                    || (entry.type == .directory && parts.count == 2 && parts[1].isEmpty),
                parts.enumerated().allSatisfy({
                    !$0.element.isEmpty
                        || ($0.offset == parts.count - 1 && entry.type == .directory)
                }),
                parts.allSatisfy({ $0 != "." && $0 != ".." }),
                entry.type != .symlink,
                seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted
            else { throw MarketplaceError.invalidArchive }
            guard entry.uncompressedSize <= limit, expandedBytes <= limit - entry.uncompressedSize
            else {
                throw MarketplaceError.invalidArchive
            }
            expandedBytes += entry.uncompressedSize
        }
        guard expandedBytes == limit else { throw MarketplaceError.invalidArchive }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in zip {
            _ = try zip.extract(entry, to: destination.appendingPathComponent(entry.path))
        }
        let payload = destination.appendingPathComponent(package.id)
        let manifest = payload.appendingPathComponent("package.json")
        guard
            try JSONDecoder().decode(
                ExtensionPayloadManifest.self, from: Data(contentsOf: manifest))
                == ExtensionPayloadManifest(package: package)
        else {
            throw MarketplaceError.invalidArchive
        }
        let bundles = try FileManager.default.contentsOfDirectory(
            at: payload, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "bundle" }
        guard !bundles.isEmpty,
            bundles.allSatisfy({
                ["app.bundle", "helper.bundle", "agent.bundle", "cli.bundle"].contains(
                    $0.lastPathComponent)
            })
        else {
            throw MarketplaceError.invalidArchive
        }
    }
}

public actor ExtensionPackageInstaller {
    public typealias Download = @Sendable (URL, Int64) async throws -> URL
    public typealias Verify = @Sendable (URL) throws -> Void
    public let store: ExtensionPackageStore
    private let download: Download
    private let verify: Verify
    private var busy = false

    public init(
        store: ExtensionPackageStore, download: @escaping Download, verify: @escaping Verify
    ) {
        self.store = store
        self.download = download
        self.verify = verify
    }

    public static func live(store: ExtensionPackageStore, teamIdentifier: String)
        -> ExtensionPackageInstaller
    {
        ExtensionPackageInstaller(
            store: store,
            download: { url, expectedBytes in
                let (file, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                    (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        == Int(expectedBytes)
                else {
                    try? FileManager.default.removeItem(at: file)
                    throw MarketplaceError.downloadFailed
                }
                return file
            },
            verify: { directory in
                for bundle in try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)
                where bundle.pathExtension == "bundle" {
                    try ExtensionCodeSignature.verify(bundle, teamIdentifier: teamIdentifier)
                }
            })
    }

    public func install(
        _ plan: [ExtensionPackage], repository: String,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [ExtensionPackage] {
        guard !busy else { throw MarketplaceError.packageBusy }
        busy = true
        defer { busy = false }
        let operation = try PackageFileLock(
            url: store.root.appendingPathComponent(".operation.lock"), exclusive: true)
        defer { operation.close() }
        for package in plan { try package.validate(repository: repository) }
        guard Set(plan.map(\.id)).count == plan.count else { throw MarketplaceError.invalidCatalog }
        let original = try store.installedPackages()
        var resulting = original
        var added: [URL] = []
        let temporary = store.root.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            for (index, package) in plan.enumerated() {
                try Task.checkCancellation()
                let existing = original.first {
                    $0.id == package.id && $0.hostABI == package.hostABI
                        && $0.architecture == package.architecture && $0.version == package.version
                }
                let directory = store.directory(for: package)
                if existing == package, FileManager.default.fileExists(atPath: directory.path) {
                    try verify(directory.appendingPathComponent(package.id))
                } else {
                    if FileManager.default.fileExists(atPath: directory.path) {
                        let stale = directory.appendingPathComponent(package.id)
                            .appendingPathComponent("package.json")
                        guard
                            (try? JSONDecoder().decode(
                                ExtensionPayloadManifest.self, from: Data(contentsOf: stale)))
                                == ExtensionPayloadManifest(package: package)
                        else { throw MarketplaceError.invalidArchive }
                        let lease = try PackageFileLock(
                            url: store.leaseURL(for: package), exclusive: true)
                        defer { lease.close() }
                        try FileManager.default.removeItem(at: directory)
                    }
                    let archive = try await download(package.downloadURL, package.downloadBytes)
                    defer { try? FileManager.default.removeItem(at: archive) }
                    try Task.checkCancellation()
                    let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
                    guard bytes.count == package.downloadBytes else {
                        throw MarketplaceError.downloadFailed
                    }
                    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }
                        .joined()
                    guard digest == package.sha256 else { throw MarketplaceError.checksumMismatch }
                    let staging = temporary.appendingPathComponent(package.id)
                    try ExtensionArchive.extract(archive, package: package, to: staging)
                    try verify(staging.appendingPathComponent(package.id))
                    try FileManager.default.createDirectory(
                        at: directory.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(at: staging, to: directory)
                    added.append(directory)
                }
                resulting.removeAll {
                    $0.id == package.id && $0.hostABI == package.hostABI
                        && $0.architecture == package.architecture && $0.version == package.version
                }
                resulting.append(package)
                progress(Double(index + 1) / Double(plan.count))
            }
            try Task.checkCancellation()
            try store.commit(resulting)
            return resulting
        } catch {
            for directory in added { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }
}

public enum ExtensionCodeSignature {
    public static func verify(_ bundle: URL, teamIdentifier: String) throws {
        guard !teamIdentifier.isEmpty,
            teamIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            throw MarketplaceError.invalidSignature
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code
        else {
            throw MarketplaceError.invalidSignature
        }
        var requirement: SecRequirement?
        let expression =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        guard
            SecRequirementCreateWithString(expression as CFString, [], &requirement)
                == errSecSuccess,
            let requirement,
            SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode),
                requirement) == errSecSuccess
        else { throw MarketplaceError.invalidSignature }
    }
}
