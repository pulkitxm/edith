import Foundation

enum ChromeLocalStorage {
    static func read(directory: URL) throws -> [String: [String: String]] {
        var origins: [String: [String: String]] = [:]
        for (key, value) in try LevelDBReader.liveEntries(inDirectory: directory) {
            guard let decoded = storageKey(key), let string = decodeString(value) else { continue }
            origins[decoded.origin, default: [:]][decoded.name] = string
        }
        return origins
    }

    static func storageKey(_ key: Data) -> (origin: String, name: String)? {
        let bytes = [UInt8](key)
        guard bytes.first == 0x5F, let separator = bytes.firstIndex(of: 0),
            separator > 1,
            let origin = String(bytes: bytes[1..<separator], encoding: .ascii),
            origin.hasPrefix("http://") || origin.hasPrefix("https://"),
            !origin.contains("^"),
            let name = decodeString(Data(bytes[(separator + 1)...]))
        else { return nil }
        return (origin, name)
    }

    static func decodeString(_ data: Data) -> String? {
        guard let encoding = data.first else { return nil }
        let payload = data.dropFirst()
        switch encoding {
        case 0:
            guard payload.count.isMultiple(of: 2) else { return nil }
            if payload.isEmpty { return "" }
            return String(data: Data(payload), encoding: .utf16LittleEndian)
        case 1:
            return String(decoding: payload.map { UInt16($0) }, as: UTF16.self)
        default:
            return nil
        }
    }
}
