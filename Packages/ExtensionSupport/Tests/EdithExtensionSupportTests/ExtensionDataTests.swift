import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite struct ExtensionDataTests {
    @Test func explicitWorkerDirectoryIsUsedWithoutTouchingOtherNamespaces() {
        let fallback = URL(fileURLWithPath: "/tmp/fixture/fallback", isDirectory: true)
        let root = ExtensionData.resolve(
            environment: ["EDITH_EXTENSION_DATA_ROOT": "/tmp/fixture/extensions/homebrew"],
            fallback: fallback)
        #expect(root.path == "/tmp/fixture/extensions/homebrew")
        #expect(ExtensionData.resolve(environment: [:], fallback: fallback) == fallback)
    }

    @Test(arguments: ["attention", "socialManager"])
    func productionStoresKeepTheirOriginalRoot(_ owner: String) {
        let root = URL(fileURLWithPath: "/tmp/fixture/Edith", isDirectory: true)
        let configured = root.appendingPathComponent("Data/" + owner, isDirectory: true)
        let fallback = URL(fileURLWithPath: "/tmp/fixture/fallback")
        let environment = [
            "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith",
            "EDITH_EXTENSION_ID": owner,
            "EDITH_EXTENSION_DATA_ROOT": configured.path,
        ]
        #expect(ExtensionData.resolve(environment: environment, fallback: fallback) == root)
        var development = environment
        development["EDITH_APPLICATION_IDENTIFIER"] = "com.pulkit.edith.dev.fixture"
        #expect(ExtensionData.resolve(environment: development, fallback: fallback) == configured)
    }

    @Test(arguments: ["", "relative/path", "/tmp/invalid\0path"])
    func invalidDirectoriesUseTheIsolatedFallback(_ path: String) {
        let fallback = URL(fileURLWithPath: "/tmp/fixture/fallback", isDirectory: true)
        #expect(
            ExtensionData.resolve(
                environment: ["EDITH_EXTENSION_DATA_ROOT": path], fallback: fallback) == fallback)
    }
}
