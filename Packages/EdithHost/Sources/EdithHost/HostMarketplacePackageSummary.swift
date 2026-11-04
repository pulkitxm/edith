import ExtensionMarketplace
import Foundation

struct HostMarketplacePackageSummary: Equatable {
    let facts: [String]

    init(candidate: ExtensionPackage?, downloadedVersions: [ExtensionPackage]) {
        var facts: [String] = []
        if let candidate {
            facts.append("Version \(candidate.version)")
            facts.append("\(Self.bytes(candidate.downloadBytes)) download")
            facts.append("\(Self.bytes(candidate.installedBytes)) unpacked")
        }
        let kept = Set(
            downloadedVersions.map { $0.hostABI + "/" + $0.architecture + "/" + $0.version }
        )
        .count
        if kept > 1 { facts.append("\(kept) versions kept") }
        self.facts = facts
    }

    var line: String? { facts.isEmpty ? nil : facts.joined(separator: " · ") }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
