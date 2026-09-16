import Foundation

public enum VolumeCapacity {
    public static let resourceKeys: Set<URLResourceKey> = [
        .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]

    public static func availableBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return nil }
        return availableBytes(in: values)
    }

    public static func availableBytes(in values: URLResourceValues) -> Int64? {
        resolve(
            important: values.volumeAvailableCapacityForImportantUsage,
            available: values.volumeAvailableCapacity.map(Int64.init))
    }

    static func resolve(important: Int64?, available: Int64?) -> Int64? {
        [important, available].compactMap { $0 }.filter { $0 >= 0 }.max()
    }
}
