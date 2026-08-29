import Foundation

public struct ScreenRecordingTake: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var source: ScreenRecordingSource
    public var createdAt: Date
    public var completedAt: Date?
    public var duration: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hasSystemAudio: Bool
    public var hasMicrophone: Bool

    public init(
        id: UUID = UUID(), source: ScreenRecordingSource, createdAt: Date = Date(),
        completedAt: Date? = nil, duration: Double = 0, pixelWidth: Int = 0,
        pixelHeight: Int = 0, hasSystemAudio: Bool = false, hasMicrophone: Bool = false
    ) {
        self.id = id
        self.source = source
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hasSystemAudio = hasSystemAudio
        self.hasMicrophone = hasMicrophone
    }
}

public enum ScreenRecordingLibrary {
    public static let maximumCount = 8
    public static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let unfinishedLifetime: TimeInterval = 7 * 24 * 60 * 60

    public static func defaultDirectory() throws -> URL {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { throw CocoaError(.fileNoSuchFile) }
        return root.appendingPathComponent("Edith/Capture Studio/Recordings", isDirectory: true)
    }

    public static func makeTake(
        source: ScreenRecordingSource, in directory: URL? = nil, now: Date = Date()
    ) throws -> ScreenRecordingTake {
        let directory = try directory ?? defaultDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let take = ScreenRecordingTake(source: source, createdAt: now)
        let folder = folderURL(for: take.id, in: directory)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try persist(take, in: directory)
        return take
    }

    public static func update(
        _ take: ScreenRecordingTake, in directory: URL? = nil
    ) throws {
        try persist(take, in: try directory ?? defaultDirectory())
    }

    public static func load(from directory: URL? = nil) -> [ScreenRecordingTake] {
        guard let directory = try? directory ?? defaultDirectory(),
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names.compactMap { UUID(uuidString: $0) }.compactMap { id in
            let url = metadataURL(for: id, in: directory)
            guard let data = try? Data(contentsOf: url),
                let take = try? JSONDecoder().decode(ScreenRecordingTake.self, from: data),
                take.id == id,
                isRegularFile(masterURL(for: id, in: directory))
            else { return nil }
            return take
        }.sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    public static func prune(
        in directory: URL? = nil, keeping: Set<UUID> = [], now: Date = Date()
    ) {
        guard let directory = try? directory ?? defaultDirectory(),
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        let folders = names.compactMap { name -> (UUID, URL)? in
            guard let id = UUID(uuidString: name) else { return nil }
            return (id, folderURL(for: id, in: directory))
        }
        var completed = load(from: directory).filter { $0.completedAt != nil }
        var bytes: Int64 = 0
        var kept: Set<UUID> = keeping
        var completedCount = 0
        for take in completed {
            let size = fileSize(masterURL(for: take.id, in: directory))
            if completedCount < maximumCount, completedCount == 0 || bytes + size <= maximumBytes {
                kept.insert(take.id)
                bytes += size
                completedCount += 1
            }
        }
        completed.removeAll()
        for (id, folder) in folders where !kept.contains(id) {
            let metadata = metadataURL(for: id, in: directory)
            let take = (try? Data(contentsOf: metadata)).flatMap {
                try? JSONDecoder().decode(ScreenRecordingTake.self, from: $0)
            }
            let expired = take.map {
                $0.completedAt != nil || now.timeIntervalSince($0.createdAt) > unfinishedLifetime
            } ?? true
            if expired { try? FileManager.default.removeItem(at: folder) }
        }
    }

    public static func remove(_ take: ScreenRecordingTake, from directory: URL? = nil) {
        guard let directory = try? directory ?? defaultDirectory() else { return }
        try? FileManager.default.removeItem(at: folderURL(for: take.id, in: directory))
    }

    public static func folderURL(for id: UUID, in directory: URL? = nil) -> URL {
        let root = (try? directory ?? defaultDirectory()) ?? URL(fileURLWithPath: "/dev/null")
        return root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public static func masterURL(for id: UUID, in directory: URL? = nil) -> URL {
        folderURL(for: id, in: directory).appendingPathComponent("master.mov")
    }

    public static func pointerURL(for id: UUID, in directory: URL? = nil) -> URL {
        folderURL(for: id, in: directory).appendingPathComponent("pointer.json")
    }

    public static func editURL(for id: UUID, in directory: URL? = nil) -> URL {
        folderURL(for: id, in: directory).appendingPathComponent("edit.json")
    }

    private static func metadataURL(for id: UUID, in directory: URL) -> URL {
        folderURL(for: id, in: directory).appendingPathComponent("take.json")
    }

    private static func persist(_ take: ScreenRecordingTake, in directory: URL) throws {
        try FileManager.default.createDirectory(
            at: folderURL(for: take.id, in: directory), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(take)
        try data.write(to: metadataURL(for: take.id, in: directory), options: [.atomic])
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
            && (values.fileSize ?? 0) > 0
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
