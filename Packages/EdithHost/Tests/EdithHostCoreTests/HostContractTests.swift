import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostContractTests {
    @Test func releaseLaunchRequiresTheInstalledApplication() {
        #expect(
            HostContract.permitsLaunching(
                identifier: "com.pulkit.edith",
                bundleURL: URL(fileURLWithPath: "/Applications/Edith.app")))
        for path in ["/synthetic/dist/Edith.app", "/Applications/Edith Copy.app", "/tmp/Edith.app"]
        {
            let bundle = URL(fileURLWithPath: path)
            #expect(
                !HostContract.permitsLaunching(identifier: "com.pulkit.edith", bundleURL: bundle))
            #expect(
                HostContract.permitsLaunching(
                    identifier: "com.pulkit.edith.dev.synthetic", bundleURL: bundle))
            #expect(
                HostContract.permitsLaunching(
                    identifier: "com.pulkit.edith.tests.synthetic", bundleURL: bundle))
        }
    }

    @Test func bundledIndexContainsOnlyExtensionMetadata() throws {
        let entries = try HostIndex.bundled()
        #expect(entries.count >= 35)
        #expect(entries.contains { $0.id == "music" })
        #expect(entries.contains { $0.id == "database" })
        #expect(entries.contains { $0.id == "keepAwake" })
    }

    @Test func invalidOrDuplicatedIdentifiersAreRejected() throws {
        let valid = HostExtension(
            id: "example", title: "Example", symbolName: "square", category: "Tools")
        let invalid = HostExtension(
            id: "../example", title: "Example", symbolName: "square", category: "Tools")
        for entries in [[valid, valid], [invalid], []] {
            #expect(throws: (any Error).self) {
                try HostIndex.load(data: JSONEncoder().encode(entries))
            }
        }
    }

    @Test func developmentIdentitiesNeverUseProductionStorage() throws {
        let support = URL(fileURLWithPath: "/synthetic/support")
        let production = try HostIdentity(identifier: "com.pulkit.edith", supportDirectory: support)
        let development = try HostIdentity(
            identifier: "com.pulkit.edith.dev.example", supportDirectory: support)
        let tests = try HostIdentity(
            identifier: "com.pulkit.edith.tests.example", supportDirectory: support)
        #expect(tests.root != development.root)
        #expect(production.root != development.root)
        #expect(production.defaultsSuite != development.defaultsSuite)
        #expect(
            production.extensionDefaultsSuite("sample")
                != development.extensionDefaultsSuite("sample"))
        #expect(development.development)
        #expect(!production.development)
        for identifier in [
            "com.pulkit.edith.dev../sample", "com.pulkit.edith.dev..",
            "com.pulkit.edith.dev.example..slot", "com.pulkit.edith.dev.",
        ] {
            #expect(throws: (any Error).self) {
                try HostIdentity(identifier: identifier, supportDirectory: support)
            }
        }
    }

    @Test func featuresCannotStartBeforeInstallation() throws {
        var activation = HostActivation(installed: false)
        #expect(throws: (any Error).self) { try activation.beginStart() }
        activation.installed()
        try activation.beginStart()
        try activation.started()
        #expect(activation.state == .active)
    }

    @Test func stoppingMustCompleteBeforeRemoval() throws {
        var activation = HostActivation(installed: true)
        try activation.beginStart()
        try activation.started()
        #expect(throws: (any Error).self) { try activation.removed() }
        try activation.beginStop()
        #expect(throws: (any Error).self) { try activation.removed() }
        try activation.stopped()
        try activation.removed()
        #expect(activation.state == .notInstalled)
    }

    @Test func failureCanBeRetriedWithoutClaimingActivation() throws {
        var activation = HostActivation(installed: true)
        try activation.beginStart()
        activation.failed()
        #expect(activation.state == .failed)
        try activation.beginStart()
        #expect(activation.state == .starting)
    }
}
