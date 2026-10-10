import EdithHostCore
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHost

@MainActor struct HostMarketplacePackageSummaryTests {
    @Test func uninstalledCandidateShowsAnEstimateWithoutClaimingInstalledBytes() {
        let value = HostMarketplacePackageSummary(
            candidate: package("2.0.0"), downloadedVersions: [])
        #expect(value.estimate?.contains("Version 2.0.0") == true)
        #expect(value.estimate?.contains("unpacked package contents") == true)
        #expect(value.estimate?.contains("installed") == false)
        #expect(value.downloaded == nil)
    }

    @Test func candidateAndRetainedVersionCountsStayDistinct() {
        let old = package("1.0.0"), selected = package("1.1.0")
        let value = HostMarketplacePackageSummary(
            candidate: package("2.0.0"), downloadedVersions: [old, selected, old])
        #expect(value.estimate?.contains("Version 2.0.0") == true)
        #expect(
            value.downloaded?.contains("2 downloaded versions, including retained copies") == true)
        #expect(value.downloaded?.contains("Storage for measured disk use") == true)
        #expect(value.downloaded?.contains("2.0.0") == false)
    }

    @Test func offlineInstalledVersionDoesNotInventDiskMeasurement() {
        let installed = package("1.0.0")
        let value = HostMarketplacePackageSummary(
            candidate: nil, downloadedVersions: [installed])
        #expect(value.estimate == nil)
        #expect(value.downloaded?.hasPrefix("1 downloaded version.") == true)
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
            architecture: "arm64", minimumSystemVersion: 14,
            downloadURL: URL(string: "https://example.invalid/sample.zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 100,
            installedBytes: 200, dependencies: [])
    }
}
