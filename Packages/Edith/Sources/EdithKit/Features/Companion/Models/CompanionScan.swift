import Foundation

public struct CompanionScanResult: Equatable, Sendable {
    public let files: [CompanionIngestFile]
    public let skipped: [String]

    public init(files: [CompanionIngestFile], skipped: [String]) {
        self.files = files
        self.skipped = skipped
    }
}

public struct CompanionAudioFile: Equatable, Sendable {
    public let name: String
    public let data: Data
    public let mtime: String?

    public init(name: String, data: Data, mtime: String? = nil) {
        self.name = name
        self.data = data
        self.mtime = mtime
    }
}

public struct CompanionAudioScanResult: Equatable, Sendable {
    public let files: [CompanionAudioFile]
    public let skipped: [String]

    public init(files: [CompanionAudioFile], skipped: [String]) {
        self.files = files
        self.skipped = skipped
    }
}

public enum CompanionScan {
    public static let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "ogg", "flac", "aiff"]

    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif",
    ]

    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi"]

    public static func imageFiles(
        at url: URL, limit maximumByteSize: Int = 48 * 1024 * 1024
    ) throws -> CompanionAudioScanResult {
        try binaryFiles(at: url, extensions: imageExtensions, maximumByteSize: maximumByteSize)
    }

    public static func videoFiles(
        at url: URL, limit maximumByteSize: Int = 768 * 1024 * 1024
    ) throws -> CompanionAudioScanResult {
        try binaryFiles(at: url, extensions: videoExtensions, maximumByteSize: maximumByteSize)
    }

    public static func pdfFiles(
        at url: URL, limit maximumByteSize: Int = 48 * 1024 * 1024
    ) throws -> CompanionAudioScanResult {
        try binaryFiles(
            at: url, extensions: ["pdf"], maximumByteSize: maximumByteSize)
    }

    public static func audioFiles(
        at url: URL, limit maximumByteSize: Int = 48 * 1024 * 1024
    ) throws -> CompanionAudioScanResult {
        try binaryFiles(
            at: url, extensions: audioExtensions, maximumByteSize: maximumByteSize)
    }

    private static func binaryFiles(
        at url: URL, extensions: Set<String>, maximumByteSize: Int
    ) throws -> CompanionAudioScanResult {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isRegularFile == true {
            guard extensions.contains(url.pathExtension.lowercased()) else {
                return CompanionAudioScanResult(files: [], skipped: [])
            }
            return try scanAudio(urls: [url], relativeTo: nil, maximumByteSize: maximumByteSize)
        }
        guard values.isDirectory == true else {
            return CompanionAudioScanResult(files: [], skipped: [])
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else {
            return CompanionAudioScanResult(files: [], skipped: [])
        }
        let matches = enumerator.compactMap { item -> URL? in
            guard let item = item as? URL,
                extensions.contains(item.pathExtension.lowercased())
            else { return nil }
            let itemValues = try? item.resourceValues(forKeys: [.isRegularFileKey])
            return itemValues?.isRegularFile == true ? item : nil
        }
        return try scanAudio(urls: matches, relativeTo: url, maximumByteSize: maximumByteSize)
    }

    private static func scanAudio(
        urls: [URL], relativeTo root: URL?, maximumByteSize: Int
    ) throws -> CompanionAudioScanResult {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var files: [CompanionAudioFile] = []
        var skipped: [String] = []
        for url in urls {
            let name = relativeName(for: url, root: root)
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard values.fileSize.map({ $0 <= maximumByteSize }) ?? true else {
                skipped.append(name)
                continue
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maximumByteSize else {
                skipped.append(name)
                continue
            }
            files.append(
                CompanionAudioFile(
                    name: name, data: data,
                    mtime: values.contentModificationDate.map { formatter.string(from: $0) }))
        }
        return CompanionAudioScanResult(
            files: files.sorted { $0.name < $1.name }, skipped: skipped.sorted())
    }

    public static func markdownFiles(
        at url: URL, limit maximumByteSize: Int = 2 * 1024 * 1024
    ) throws -> CompanionScanResult {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isRegularFile == true {
            guard url.pathExtension.lowercased() == "md" else {
                return CompanionScanResult(files: [], skipped: [])
            }
            return try scan(urls: [url], relativeTo: nil, maximumByteSize: maximumByteSize)
        }
        guard values.isDirectory == true else {
            return CompanionScanResult(files: [], skipped: [])
        }
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else {
            return CompanionScanResult(files: [], skipped: [])
        }
        let markdown = enumerator.compactMap { item -> URL? in
            guard let item = item as? URL, item.pathExtension.lowercased() == "md" else {
                return nil
            }
            let itemValues = try? item.resourceValues(forKeys: [.isRegularFileKey])
            return itemValues?.isRegularFile == true ? item : nil
        }
        return try scan(urls: markdown, relativeTo: url, maximumByteSize: maximumByteSize)
    }

    private static func scan(
        urls: [URL], relativeTo root: URL?, maximumByteSize: Int
    ) throws -> CompanionScanResult {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var files: [CompanionIngestFile] = []
        var skipped: [String] = []
        for url in urls {
            let name = relativeName(for: url, root: root)
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard values.fileSize.map({ $0 <= maximumByteSize }) ?? true else {
                skipped.append(name)
                continue
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maximumByteSize else {
                skipped.append(name)
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            files.append(
                CompanionIngestFile(
                    name: name, text: text,
                    mtime: values.contentModificationDate.map { formatter.string(from: $0) }))
        }
        return CompanionScanResult(
            files: files.sorted { $0.name < $1.name }, skipped: skipped.sorted())
    }

    private static func relativeName(for url: URL, root: URL?) -> String {
        guard let root else { return url.lastPathComponent }
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }
}
