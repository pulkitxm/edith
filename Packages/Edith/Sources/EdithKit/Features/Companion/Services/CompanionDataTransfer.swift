import Foundation

public enum CompanionDataTransferError: LocalizedError {
    case notABundle(String)
    case unreadable(String, String)
    case unwritable(String, String)
    case missingBundle(String)

    public var errorDescription: String? {
        switch self {
        case let .notABundle(detail):
            return "the companion sent something that is not an export bundle: \(detail)"
        case let .unreadable(path, detail):
            return "could not read \(path): \(detail)"
        case let .unwritable(path, detail):
            return "could not write into \(path): \(detail)"
        case let .missingBundle(path):
            return "no bundle.json inside \(path)"
        }
    }
}

public struct CompanionExportResult: Sendable {
    public let directory: String
    public let counts: [String: Int]
    public let mediaOnCompanion: Int
    public let mediaSaved: Int
    public let mediaFailed: [String]
}

public struct CompanionImportResult: Sendable {
    public let outcome: CompanionImportBundleOutcome
    public let mediaRestored: Int
    public let mediaFailed: [String]
}

public enum CompanionDataTransfer {
    public static func export(
        client: CompanionClient, into directory: URL, includeMedia: Bool
    ) async throws -> CompanionExportResult {
        let bundle = try await client.exportBundle()
        let manifest: CompanionExportManifest
        do {
            manifest = try JSONDecoder().decode(CompanionExportManifest.self, from: bundle)
        } catch {
            throw CompanionDataTransferError.notABundle(error.localizedDescription)
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try bundle.write(to: directory.appendingPathComponent("bundle.json"))
        } catch {
            throw CompanionDataTransferError.unwritable(
                directory.path, error.localizedDescription)
        }
        var saved = 0
        var failed: [String] = []
        if includeMedia, !manifest.media.isEmpty {
            let mediaDir = directory.appendingPathComponent("media")
            try? FileManager.default.createDirectory(
                at: mediaDir, withIntermediateDirectories: true)
            for item in manifest.media {
                let basename = (item.uri as NSString).lastPathComponent
                do {
                    let (data, _) = try await client.media(episodeId: item.episodeId)
                    try data.write(
                        to: mediaDir.appendingPathComponent("\(item.sha256)-\(basename)"))
                    saved += 1
                } catch {
                    failed.append(basename)
                }
            }
        }
        return CompanionExportResult(
            directory: directory.path, counts: manifest.counts,
            mediaOnCompanion: manifest.media.count, mediaSaved: saved, mediaFailed: failed)
    }

    public static func bundleURL(at path: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
        else {
            throw CompanionDataTransferError.unreadable(path.path, "nothing there")
        }
        guard isDirectory.boolValue else { return path }
        let inside = path.appendingPathComponent("bundle.json")
        guard FileManager.default.fileExists(atPath: inside.path) else {
            throw CompanionDataTransferError.missingBundle(path.path)
        }
        return inside
    }

    public static func restore(
        client: CompanionClient, from path: URL
    ) async throws -> CompanionImportResult {
        let bundleURL = try bundleURL(at: path)
        let data: Data
        do {
            data = try Data(contentsOf: bundleURL)
        } catch {
            throw CompanionDataTransferError.unreadable(
                bundleURL.path, error.localizedDescription)
        }
        let outcome = try await client.importBundle(data)
        var restored = 0
        var failed: [String] = []
        let mediaDir = bundleURL.deletingLastPathComponent().appendingPathComponent("media")
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: mediaDir.path)) ?? []
        for name in names.sorted() {
            guard let separator = name.firstIndex(of: "-"), separator != name.startIndex
            else { continue }
            let sha256 = String(name[..<separator])
            let basename = String(name[name.index(after: separator)...])
            guard sha256.count == 64 else { continue }
            do {
                let bytes = try Data(contentsOf: mediaDir.appendingPathComponent(name))
                _ = try await client.importMedia(
                    sha256: sha256, name: basename, dataB64: bytes.base64EncodedString())
                restored += 1
            } catch {
                failed.append(basename)
            }
        }
        return CompanionImportResult(
            outcome: outcome, mediaRestored: restored, mediaFailed: failed)
    }
}
