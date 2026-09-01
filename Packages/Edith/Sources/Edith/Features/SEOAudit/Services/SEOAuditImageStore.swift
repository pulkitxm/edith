import CryptoKit
import Foundation

actor SEOAuditImageStore {
    private static let maximumImageBytes = 25 * 1_024 * 1_024
    private static let imageExtensions = [
        "png", "jpg", "gif", "webp", "avif", "tiff", "bmp", "svg", "heic", "heif", "ico",
        "img",
    ]

    private let root: URL
    private let session: URLSession
    private let fileManager: FileManager
    private var cachedURLs: [String: URL] = [:]

    init(root: URL, session: URLSession = .shared, fileManager: FileManager = .default) {
        self.root = root
        self.session = session
        self.fileManager = fileManager
    }

    func capture(
        metadata: SEOAuditMetadata, projectID: UUID, runID: UUID, runStartedAt: Date
    ) async -> SEOAuditImageSnapshots {
        let openGraphSource = metadata.openGraphImageURL.flatMap(URL.init(string:))
        let twitterSource = metadata.twitterImageURL.flatMap(URL.init(string:))
        if openGraphSource == twitterSource, let source = openGraphSource {
            let snapshot = await capture(
                source, projectID: projectID, runID: runID, runStartedAt: runStartedAt)
            return SEOAuditImageSnapshots(
                openGraphImageURL: snapshot?.absoluteString,
                twitterImageURL: snapshot?.absoluteString)
        }
        let openGraphSnapshot = await capture(
            openGraphSource, projectID: projectID, runID: runID, runStartedAt: runStartedAt)
        let twitterSnapshot = await capture(
            twitterSource, projectID: projectID, runID: runID, runStartedAt: runStartedAt)
        return SEOAuditImageSnapshots(
            openGraphImageURL: openGraphSnapshot?.absoluteString,
            twitterImageURL: twitterSnapshot?.absoluteString)
    }

    private func capture(
        _ source: URL?, projectID: UUID, runID: UUID, runStartedAt: Date
    ) async -> URL? {
        guard let source, ["http", "https"].contains(source.scheme?.lowercased()) else {
            return nil
        }
        let cacheKey = "\(projectID.uuidString):\(runID.uuidString):\(source.absoluteString)"
        if let cached = cachedURLs[cacheKey] { return cached }
        let directory = runDirectory(
            projectID: projectID, runID: runID, runStartedAt: runStartedAt)
        let digest = SHA256.hash(data: Data(source.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        if let existing = existingSnapshot(digest: digest, in: directory) {
            cachedURLs[cacheKey] = existing
            return existing
        }
        do {
            var request = URLRequest(url: source)
            request.timeoutInterval = 30
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            request.setValue("Edith SEO Audit", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard !data.isEmpty, data.count <= Self.maximumImageBytes,
                let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                let mimeType = http.mimeType?.lowercased(), mimeType.hasPrefix("image/")
            else { return nil }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(
                "\(digest).\(fileExtension(mimeType: mimeType, source: source))")
            try data.write(to: file, options: .atomic)
            cachedURLs[cacheKey] = file
            return file
        } catch {
            return nil
        }
    }

    private func runDirectory(projectID: UUID, runID: UUID, runStartedAt: Date) -> URL {
        let timestamp = Int(runStartedAt.timeIntervalSince1970)
        return root.appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(projectID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(
                "\(timestamp)-\(runID.uuidString.lowercased())", isDirectory: true)
    }

    private func existingSnapshot(digest: String, in directory: URL) -> URL? {
        for fileExtension in Self.imageExtensions {
            let file = directory.appendingPathComponent("\(digest).\(fileExtension)")
            if fileManager.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    private func fileExtension(mimeType: String, source: URL) -> String {
        switch mimeType {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/avif": return "avif"
        case "image/tiff": return "tiff"
        case "image/bmp": return "bmp"
        case "image/svg+xml": return "svg"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/x-icon", "image/vnd.microsoft.icon": return "ico"
        default:
            let sourceExtension = source.pathExtension.lowercased()
            return Self.imageExtensions.contains(sourceExtension) ? sourceExtension : "img"
        }
    }
}
