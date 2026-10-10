import CryptoKit
import Foundation

public enum MarketplaceError: Error, Equatable, LocalizedError, Sendable {
    case invalidCatalog
    case invalidSignature
    case incompatiblePackage
    case downloadFailed
    case invalidArchive
    case checksumMismatch
    case packageNotInstalled
    case packageBusy
    case invalidBundle
    case dependencyInUse

    public var errorDescription: String? {
        switch self {
        case .invalidCatalog: "The extension catalog is invalid."
        case .invalidSignature: "The extension publisher could not be verified."
        case .incompatiblePackage: "This extension needs a compatible version of Edith."
        case .downloadFailed: "The extension download failed. Try again."
        case .invalidArchive: "The extension package could not be installed safely."
        case .checksumMismatch: "The extension download did not match its published checksum."
        case .packageNotInstalled: "Download this extension before enabling it."
        case .packageBusy: "An operation is already running for this extension."
        case .invalidBundle: "The extension bundle could not be loaded."
        case .dependencyInUse:
            "Another installed extension needs this package. Remove that extension first."
        }
    }
}

public struct ExtensionPackage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let version: String
    public let hostABI: String
    public let architecture: String
    public let minimumSystemVersion: Int
    public let downloadURL: URL
    public let sha256: String
    public let downloadBytes: Int64
    public let installedBytes: Int64
    public let dependencies: [String]

    public init(
        id: String, version: String, hostABI: String, architecture: String = "arm64",
        minimumSystemVersion: Int = 14, downloadURL: URL, sha256: String,
        downloadBytes: Int64, installedBytes: Int64, dependencies: [String] = []
    ) {
        self.id = id
        self.version = version
        self.hostABI = hostABI
        self.architecture = architecture
        self.minimumSystemVersion = minimumSystemVersion
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.downloadBytes = downloadBytes
        self.installedBytes = installedBytes
        self.dependencies = dependencies
    }

    public static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 96
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn:
                        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._"
                ).contains($0)
            } && value != "." && value != ".." && !value.hasPrefix(".")
    }

    public func isCompatible(hostABI: String, architecture: String, systemVersion: Int) -> Bool {
        self.hostABI == hostABI && self.architecture == architecture
            && systemVersion >= minimumSystemVersion
    }

    public func validate(repository: String) throws {
        guard Self.validComponent(id), Self.validComponent(version), Self.validComponent(hostABI),
            version.split(separator: ".", omittingEmptySubsequences: false).count == 3,
            version.split(separator: ".").allSatisfy({
                !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber })
            }),
            architecture == "arm64" || architecture == "x86_64", minimumSystemVersion >= 14,
            downloadBytes > 0, downloadBytes <= 512 * 1024 * 1024,
            installedBytes > 0, installedBytes <= 1024 * 1024 * 1024,
            sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
            dependencies.allSatisfy(Self.validComponent),
            Set(dependencies).count == dependencies.count,
            !dependencies.contains(id), downloadURL.scheme == "https",
            downloadURL.host == "github.com", downloadURL.user == nil, downloadURL.password == nil,
            downloadURL.port == nil, downloadURL.query == nil, downloadURL.fragment == nil,
            downloadURL.path.hasPrefix("/\(repository)/releases/download/"),
            downloadURL.lastPathComponent == "\(id).zip"
        else { throw MarketplaceError.invalidCatalog }
    }
}

public struct ExtensionCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: Int64
    public let packages: [ExtensionPackage]

    public init(revision: Int64, packages: [ExtensionPackage]) {
        schemaVersion = 1
        self.revision = revision
        self.packages = packages
    }

    public func validate(repository: String) throws {
        guard schemaVersion == 1, revision >= 0, packages.count <= 1000 else {
            throw MarketplaceError.invalidCatalog
        }
        var identities = Set<String>()
        for package in packages {
            try package.validate(repository: repository)
            guard
                identities.insert(
                    "\(package.id)/\(package.hostABI)/\(package.version)/\(package.architecture)"
                ).inserted
            else {
                throw MarketplaceError.invalidCatalog
            }
        }
        for package in packages {
            guard
                package.dependencies.allSatisfy({ dependency in
                    packages.contains {
                        $0.id == dependency && $0.hostABI == package.hostABI
                            && $0.architecture == package.architecture
                    }
                })
            else { throw MarketplaceError.invalidCatalog }
        }
    }

    public func installationPlan(
        for id: String, hostABI: String, architecture: String, systemVersion: Int
    ) throws -> [ExtensionPackage] {
        var result: [ExtensionPackage] = []
        var visiting = Set<String>()
        var visited = Set<String>()
        func visit(_ id: String) throws {
            guard !visiting.contains(id) else { throw MarketplaceError.invalidCatalog }
            if visited.contains(id) { return }
            guard
                let package = packages.filter({
                    $0.id == id
                        && $0.isCompatible(
                            hostABI: hostABI, architecture: architecture,
                            systemVersion: systemVersion)
                }).max(by: {
                    $0.version.compare($1.version, options: .numeric) == .orderedAscending
                })
            else {
                throw MarketplaceError.incompatiblePackage
            }
            visiting.insert(id)
            for dependency in package.dependencies { try visit(dependency) }
            visiting.remove(id)
            visited.insert(id)
            result.append(package)
        }
        try visit(id)
        return result
    }
}

public struct SignedExtensionCatalog: Codable, Sendable {
    public let payload: Data
    public let signature: Data

    public init(payload: Data, signature: Data) {
        self.payload = payload
        self.signature = signature
    }

    public func verified(publicKey: Data, repository: String, minimumRevision: Int64 = 0) throws
        -> ExtensionCatalog
    {
        guard payload.count <= 2 * 1024 * 1024,
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
            key.isValidSignature(signature, for: payload)
        else { throw MarketplaceError.invalidSignature }
        let catalog = try JSONDecoder().decode(ExtensionCatalog.self, from: payload)
        try catalog.validate(repository: repository)
        guard catalog.revision >= minimumRevision else { throw MarketplaceError.invalidCatalog }
        return catalog
    }
}
