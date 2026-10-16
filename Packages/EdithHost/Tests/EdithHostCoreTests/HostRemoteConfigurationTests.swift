import ExtensionMarketplace
import Foundation
import Testing
@testable import EdithHostCore

struct HostRemoteConfigurationTests {
    @Test func aSealedPackageAndHostMustMatchBeforeUIConfiguration() throws {
        let identifier = "com.pulkit.edith.tests.remote-configuration-\(UUID().uuidString)"
        let identity = try HostIdentity(
            identifier: identifier, supportDirectory: FileManager.default.temporaryDirectory)
        let worker = HostWorkerConfiguration(
            identity: identity, extensionID: "music", version: "1.0.0")
        let package = ExtensionPackage(
            id: "music", version: "1.0.0", hostABI: MarketplaceConfiguration.workerHostABI,
            downloadURL: URL(
                string: "https://github.com/example/app/releases/download/mock/music.zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
        let configuration = HostRemoteConfiguration(
            session: UUID(), worker: worker, package: package, uiOnly: true)
        try configuration.validate(
            hostIdentifier: identifier, extensionID: "music", version: "1.0.0")
        for (host, id, version) in [
            (identifier + ".other", "music", "1.0.0"),
            (identifier, "database", "1.0.0"), (identifier, "music", "2.0.0"),
        ] {
            #expect(throws: HostWorkerError.rejected) {
                try configuration.validate(hostIdentifier: host, extensionID: id, version: version)
            }
        }
        var recovery = worker
        recovery.recoveryOnly = true
        let rejected = HostRemoteConfiguration(
            session: UUID(), worker: recovery, package: package, uiOnly: false)
        #expect(throws: HostWorkerError.rejected) {
            try rejected.validate(
                hostIdentifier: identifier, extensionID: "music", version: "1.0.0")
        }
        #expect(throws: HostWorkerError.rejected) {
            try HostRemoteSceneDescriptor(
                slot: HostRemoteSceneDescriptor.maximumScenes, presentationID: UUID())
        }
        #expect(throws: HostWorkerError.rejected) {
            try HostRemoteSceneDescriptor(slot: -1, presentationID: UUID())
        }
    }
}
