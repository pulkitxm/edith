import CryptoKit
import Foundation

public struct ExtensionSideload: Sendable, Equatable {
    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case missing(String)
        case ambiguous(String)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let path):
                "No built extension package was found at \(path). Build one with make extension-sideload."
            case .ambiguous(let path):
                "\(path) holds several built packages. Pass the .zip of the one to sideload."
            case .unreadable(let path):
                "\(path) is not a built extension package record."
            }
        }
    }

    public let package: ExtensionPackage
    public let archive: URL

    public init(path: URL, fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            throw Failure.missing(path.path)
        }
        let record: URL
        if isDirectory.boolValue {
            let records = try fileManager.contentsOfDirectory(
                at: path, includingPropertiesForKeys: nil
            ).filter {
                $0.pathExtension == "json"
                    && fileManager.fileExists(
                        atPath: $0.deletingPathExtension().appendingPathExtension("zip").path)
            }
            guard let only = records.first else { throw Failure.missing(path.path) }
            guard records.count == 1 else { throw Failure.ambiguous(path.path) }
            record = only
        } else {
            guard ["zip", "json"].contains(path.pathExtension) else {
                throw Failure.unreadable(path.path)
            }
            record = path.deletingPathExtension().appendingPathExtension("json")
        }
        let archive = record.deletingPathExtension().appendingPathExtension("zip")
        guard fileManager.fileExists(atPath: record.path),
            fileManager.fileExists(atPath: archive.path)
        else { throw Failure.missing(path.path) }
        guard
            let package = try? JSONDecoder().decode(
                ExtensionPackage.self, from: Data(contentsOf: record)),
            archive.lastPathComponent == "\(package.id).zip"
        else { throw Failure.unreadable(record.path) }
        let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard Int64(bytes.count) == package.downloadBytes,
            SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined()
                == package.sha256
        else { throw MarketplaceError.checksumMismatch }
        self.package = package
        self.archive = archive
    }
}
