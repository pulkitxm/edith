import EdithExtensionSupport
import Foundation

public actor SurfaceUsageStore {
    public static let shared = SurfaceUsageStore()
    private struct Stamp: Equatable, Sendable {
        let modifiedAt: Date
        let size: Int
        let inode: UInt64
    }
    private var document: SurfaceUsageDocument?
    private var stamp: Stamp?
    private let url: URL

    public init(url: URL = ExtensionData.root.appendingPathComponent("data/usage.json")) {
        self.url = url
    }

    public func snapshot(tile: SurfaceTile) async throws -> SurfaceUsageSnapshot {
        let value = try await load()
        try Task.checkCancellation()
        return SurfaceUsageSnapshot(document: value, tile: tile)
    }

    public func sources() async throws -> [SurfaceSourceChoice] {
        let value = try await load()
        try Task.checkCancellation()
        let identifiers = Set(value.sourceMeta?.keys.map { $0 } ?? [])
            .union(value.daily.flatMap { $0.bySource?.keys.map { $0 } ?? [] })
        return identifiers.sorted().filter {
            !$0.isEmpty && $0.utf8.count <= 2048 && !$0.utf8.contains(0)
        }.prefix(100).map { id in
            let label = value.sourceMeta?[id]?.label ?? id
            var bytes = 0
            let scalars = label.unicodeScalars.prefix { scalar in
                bytes += String(scalar).utf8.count
                return bytes <= 1024 && scalar.value != 0
            }
            let title = String(String.UnicodeScalarView(scalars))
            return .init(id, title.isEmpty ? "Source" : title)
        }
    }

    public func clear() { document = nil; stamp = nil }

    private func load() async throws -> SurfaceUsageDocument {
        try Task.checkCancellation()
        let url = url
        let previous = stamp
        let read = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                let size = attributes[.size] as? Int, (0...67_108_864).contains(size),
                let date = attributes[.modificationDate] as? Date,
                let inode = attributes[.systemFileNumber] as? UInt64
            else { throw CocoaError(.fileReadCorruptFile) }
            let current = Stamp(modifiedAt: date, size: size, inode: inode)
            if current == previous { return (current, Optional<SurfaceUsageDocument>.none) }
            guard
                let data = try UsageDataFiles.readRegularFile(
                    at: url, maximumBytes: 67_108_864)
            else { throw CocoaError(.fileReadNoSuchFile) }
            try Task.checkCancellation()
            let document = try JSONDecoder().decode(SurfaceUsageDocument.self, from: data)
            try Task.checkCancellation()
            return (current, document)
        }
        let result = try await withTaskCancellationHandler {
            try await read.value
        } onCancel: {
            read.cancel()
        }
        try Task.checkCancellation()
        if let next = result.1 { document = next; stamp = result.0 }
        guard let document else { throw CocoaError(.fileReadCorruptFile) }
        return document
    }
}
