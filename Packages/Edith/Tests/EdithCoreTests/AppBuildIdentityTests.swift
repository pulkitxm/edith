import Foundation
import Testing

@testable import EdithCore

@Suite struct AppBuildIdentityTests {
    private func makeApp(_ identifier: String, at url: URL) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL",
            ],
            format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }

    @Test func identityFollowsTheOutermostContainingBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for identifier in [AppBuildIdentity.production, "com.pulkit.edith.dev.openscreen"] {
            let app = root.appendingPathComponent(identifier + ".app")
            try makeApp(identifier, at: app)
            let helper = app.appendingPathComponent("Contents/Library/LoginItems/Edith.app")
            try makeApp(
                identifier == AppBuildIdentity.production
                    ? "com.pulkit.edith.helper.v2" : identifier + ".helper",
                at: helper)
            for location in [app, app.appendingPathComponent("Contents/MacOS/edithd"), helper] {
                #expect(AppBuildIdentity.resolve(bundleURL: location) == identifier)
            }
        }
        #expect(AppBuildIdentity.resolve(bundleURL: root) == AppBuildIdentity.production)
    }

    @Test func foreignBundlesResolveToProduction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = root.appendingPathComponent("Probe.app")
        try makeApp("test.edith.probe", at: probe)
        #expect(AppBuildIdentity.resolve(bundleURL: probe) == AppBuildIdentity.production)
    }

    @Test func everyWorktreeSlotGetsItsOwnDirectories() {
        #expect(AppBuildIdentity.slot(of: AppBuildIdentity.production) == nil)
        #expect(AppBuildIdentity.slot(of: "com.pulkit.edith.dev.openscreen") == "openscreen")
        #expect(AppBuildIdentity.directoryName(for: AppBuildIdentity.production) == "Edith")
        #expect(
            AppBuildIdentity.directoryName(for: "com.pulkit.edith.dev.openscreen")
                == "Edith Dev/openscreen")
        let home = URL(fileURLWithPath: "/tmp/identity-fixture")
        let directories = [
            AppDirectories(homeDirectory: home),
            AppDirectories(
                homeDirectory: home,
                directoryName: AppBuildIdentity.directoryName(for: "com.pulkit.edith.dev.a")),
            AppDirectories(
                homeDirectory: home,
                directoryName: AppBuildIdentity.directoryName(for: "com.pulkit.edith.dev.b")),
        ]
        for keyPath in [\AppDirectories.data, \.cache, \.logs, \.runtime] {
            #expect(Set(directories.map { $0[keyPath: keyPath] }).count == directories.count)
        }
    }
}
