import Foundation
import Testing

@testable import EdithCore

@Suite struct AppBuildIdentityTests {
    @Test func developmentIdentityFollowsTheContainingBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for identifier in [AppBuildIdentity.production, AppBuildIdentity.development] {
            let app = root.appendingPathComponent(identifier + ".app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL",
                ],
                format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            for location in [app, contents.appendingPathComponent("MacOS/edithd")] {
                #expect(
                    AppBuildIdentity.resolve(bundleURL: location)
                        == (identifier == AppBuildIdentity.development))
            }
        }
        #expect(!AppBuildIdentity.resolve(bundleURL: root))
    }

    @Test func developmentDirectoriesDoNotShareProductionStorage() {
        let home = URL(fileURLWithPath: "/tmp/identity-fixture")
        let production = AppDirectories(homeDirectory: home)
        let development = AppDirectories(homeDirectory: home, directoryName: "Edith Development")
        #expect(production.data != development.data)
        #expect(production.cache != development.cache)
        #expect(production.logs != development.logs)
        #expect(production.runtime != development.runtime)
    }
}
