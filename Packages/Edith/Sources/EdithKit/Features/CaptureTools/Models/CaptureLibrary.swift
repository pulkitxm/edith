import AppKit
import Foundation

public struct CaptureLibraryItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let mode: CaptureMode
    public let fileName: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let recognition: CaptureRecognition

    public init(
        id: UUID = UUID(), capturedAt: Date = Date(), mode: CaptureMode,
        fileName: String, pixelWidth: Int, pixelHeight: Int,
        recognition: CaptureRecognition
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.mode = mode
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.recognition = recognition
    }
}

public enum CaptureLibraryStore {
    public static let maximumCount = 12
    public static let maximumBytes: Int64 = 256 * 1024 * 1024

    public static func defaultDirectory() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { throw CaptureScreenshotError.saveFailed }
        return support.appendingPathComponent("Edith/Capture Studio", isDirectory: true)
    }

    public static func load(from directory: URL? = nil) -> [CaptureLibraryItem] {
        guard let directory = try? directory ?? defaultDirectory(),
            let data = try? Data(contentsOf: manifestURL(in: directory)),
            let decoded = try? JSONDecoder().decode([CaptureLibraryItem].self, from: data)
        else { return [] }
        return decoded.filter {
            isSafeFileName($0.fileName)
                && FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent($0.fileName).path)
        }
    }

    public static func add(
        _ data: Data, mode: CaptureMode, recognition: CaptureRecognition,
        to directory: URL? = nil, capturedAt: Date = Date()
    ) throws -> CaptureLibraryItem {
        let directory = try directory ?? defaultDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard let image = NSImage(data: data),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw CaptureRecognitionError.unreadableImage }
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        try data.write(
            to: directory.appendingPathComponent(fileName), options: [.atomic, .completeFileProtection])
        let item = CaptureLibraryItem(
            id: id, capturedAt: capturedAt, mode: mode, fileName: fileName,
            pixelWidth: cgImage.width, pixelHeight: cgImage.height,
            recognition: recognition)
        let items = try pruned([item] + load(from: directory), in: directory)
        try persist(items, in: directory)
        return item
    }

    public static func replace(
        _ item: CaptureLibraryItem, with data: Data, in directory: URL? = nil
    ) throws {
        let directory = try directory ?? defaultDirectory()
        guard isSafeFileName(item.fileName) else { throw CaptureScreenshotError.saveFailed }
        try data.write(
            to: directory.appendingPathComponent(item.fileName),
            options: [.atomic, .completeFileProtection])
    }

    public static func remove(_ item: CaptureLibraryItem, from directory: URL? = nil) throws {
        let directory = try directory ?? defaultDirectory()
        guard isSafeFileName(item.fileName) else { throw CaptureScreenshotError.saveFailed }
        try? FileManager.default.removeItem(at: imageURL(for: item, in: directory))
        try persist(load(from: directory).filter { $0.id != item.id }, in: directory)
    }

    public static func clear(in directory: URL? = nil) throws {
        let directory = try directory ?? defaultDirectory()
        for item in load(from: directory) where isSafeFileName(item.fileName) {
            try? FileManager.default.removeItem(at: imageURL(for: item, in: directory))
        }
        try persist([], in: directory)
    }

    public static func imageURL(
        for item: CaptureLibraryItem, in directory: URL? = nil
    ) -> URL {
        let root = (try? directory ?? defaultDirectory()) ?? URL(fileURLWithPath: "/dev/null")
        return root.appendingPathComponent(item.fileName)
    }

    private static func pruned(
        _ candidates: [CaptureLibraryItem], in directory: URL
    ) throws -> [CaptureLibraryItem] {
        var kept: [CaptureLibraryItem] = []
        var bytes: Int64 = 0
        for item in candidates {
            guard kept.count < maximumCount, isSafeFileName(item.fileName) else {
                try? FileManager.default.removeItem(at: imageURL(for: item, in: directory))
                continue
            }
            let url = imageURL(for: item, in: directory)
            let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let nextBytes = bytes + Int64(max(0, size))
            guard kept.isEmpty || nextBytes <= maximumBytes else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            kept.append(item)
            bytes = nextBytes
        }
        return kept
    }

    private static func persist(_ items: [CaptureLibraryItem], in directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        try data.write(to: manifestURL(in: directory), options: [.atomic, .completeFileProtection])
    }

    private static func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("library.json")
    }

    private static func isSafeFileName(_ value: String) -> Bool {
        value == URL(fileURLWithPath: value).lastPathComponent
            && value.lowercased().hasSuffix(".png")
            && UUID(uuidString: String(value.dropLast(4))) != nil
    }
}
