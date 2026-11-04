import EdithHostCore
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHost

@MainActor struct HostMarketplacePackageSummaryTests {
    @Test func candidateShowsVersionAndSizesWithoutClaimingDiskUse() {
        let value = HostMarketplacePackageSummary(
            candidate: package("2.0.0"), downloadedVersions: [])
        #expect(value.facts == ["Version 2.0.0", "100 bytes download", "200 bytes unpacked"])
        #expect(value.line == "Version 2.0.0 · 100 bytes download · 200 bytes unpacked")
        #expect(value.line?.contains("installed") == false)
    }

    @Test func retainedVersionsAreCountedOnlyWhenMoreThanOneIsKept() {
        let old = package("1.0.0"), selected = package("1.1.0")
        let value = HostMarketplacePackageSummary(
            candidate: package("2.0.0"), downloadedVersions: [old, selected, old])
        #expect(value.facts.last == "2 versions kept")
        let single = HostMarketplacePackageSummary(
            candidate: package("2.0.0"), downloadedVersions: [old])
        #expect(!single.facts.contains { $0.contains("kept") })
    }

    @Test func offlineInstalledVersionDoesNotInventSizes() {
        let value = HostMarketplacePackageSummary(
            candidate: nil, downloadedVersions: [package("1.0.0")])
        #expect(value.facts.isEmpty)
        #expect(value.line == nil)
    }

    @Test func siteAuditFootprintUsesTheOwnedExtensionID() throws {
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.summary",
            supportDirectory: URL(fileURLWithPath: "/tmp/synthetic-storage-summary"))
        let target = try #require(
            HostStorageTarget.defaults(identity: identity).first { $0.title == "Site audits" })
        #expect(target.id == "seoAudit")
        #expect(target.url == identity.extensionDirectory("seoAudit"))
    }

    private func package(_ version: String) -> ExtensionPackage {
        ExtensionPackage(
            id: "sample", version: version, hostABI: HostContract.compatibility,
            architecture: "arm64", minimumSystemVersion: .init(major: 14),
            downloadURL: URL(string: "https://example.invalid/sample.zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 100,
            installedBytes: 200, dependencies: [])
    }
}
