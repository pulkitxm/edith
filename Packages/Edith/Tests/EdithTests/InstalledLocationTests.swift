import Foundation
import Testing

@testable import Edith

@Suite struct InstalledLocationTests {
    private let home = URL(fileURLWithPath: "/Users/fixture")

    @Test func productionRunsOnlyFromAnApplicationsFolder() {
        for path in ["/Applications/Edith.app", "/Users/fixture/Applications/Edith.app"] {
            #expect(
                InstalledLocation.permitsLaunch(
                    bundleURL: URL(fileURLWithPath: path), identifier: "com.pulkit.edith",
                    homeDirectory: home))
        }
        for path in [
            "/Users/fixture/scripts/edith-lean/dist/Edith.app",
            "/Users/fixture/scripts/edith/build/Build/Products/Release/Edith.app",
            "/Volumes/Edith/Edith.app",
        ] {
            #expect(
                !InstalledLocation.permitsLaunch(
                    bundleURL: URL(fileURLWithPath: path), identifier: "com.pulkit.edith",
                    homeDirectory: home))
        }
    }

    @Test func developmentBuildsRunFromTheirWorktree() {
        #expect(
            InstalledLocation.permitsLaunch(
                bundleURL: URL(fileURLWithPath: "/Users/fixture/scripts/edith-lean/dist/Edith.app"),
                identifier: "com.pulkit.edith.dev.lean", homeDirectory: home))
    }
}
