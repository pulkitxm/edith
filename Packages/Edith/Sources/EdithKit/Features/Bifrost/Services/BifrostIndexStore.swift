import Foundation

public struct BifrostIndexStore: Sendable {
    public static let fileName = "bifrost-index.json"

    public let location: URL

    public init(location: URL) {
        self.location = location
    }

    public static var shared: BifrostIndexStore {
        BifrostIndexStore(location: DataRoot.caches.appendingPathComponent(fileName))
    }

    public func load(fileManager: FileManager = .default) -> BifrostIndex? {
        guard let data = fileManager.contents(atPath: location.path),
            let decoded = try? JSONDecoder.bifrost.decode(BifrostIndex.self, from: data),
            decoded.isUsable
        else { return nil }
        return decoded
    }

    public func save(_ index: BifrostIndex, fileManager: FileManager = .default) {
        guard let data = try? JSONEncoder.bifrost.encode(index) else { return }
        try? fileManager.createDirectory(
            at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: location, options: .atomic)
    }

    public func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: location)
    }
}

extension JSONDecoder {
    static var bifrost: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

extension JSONEncoder {
    static var bifrost: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}
