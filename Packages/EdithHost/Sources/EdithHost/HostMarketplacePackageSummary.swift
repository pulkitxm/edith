import ExtensionMarketplace
import Foundation

struct HostMarketplacePackageSummary: Equatable {
    let estimate: String?
    let downloaded: String?

    init(candidate: ExtensionPackage?, downloadedVersions: [ExtensionPackage]) {
        estimate = candidate.map {
            "Version \($0.version): \(Self.bytes($0.downloadBytes)) download · \(Self.bytes($0.installedBytes)) unpacked package contents"
        }
        let count = Set(
            downloadedVersions.map { $0.hostABI + "/" + $0.architecture + "/" + $0.version }
        )
        .count
        downloaded =
            count == 0
            ? nil
            : "\(count) downloaded \(count == 1 ? "version" : "versions, including retained copies"). See Storage for measured disk use."
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
