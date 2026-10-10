import Foundation

public enum AppMaintenanceFiles {
    public static func directorySize(_ url: URL, isCancelled: () -> Bool = { false }) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: Array(keys), options: [])
        else {
            let single = try? url.resourceValues(forKeys: keys)
            return Int64(single?.totalFileAllocatedSize ?? single?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            if isCancelled() { break }
            guard let values = try? item.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    public static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public static func command(_ arguments: [String]) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+/=:@%,")
        return arguments.map { value in
            if !value.isEmpty, value.allSatisfy({ safe.contains($0) }) { return value }
            return
                "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
