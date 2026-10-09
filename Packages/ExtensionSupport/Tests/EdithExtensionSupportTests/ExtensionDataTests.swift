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

    @Test(arguments: ["", "relative/path", "/tmp/invalid\0path"])
    func invalidDirectoriesUseTheIsolatedFallback(_ path: String) {
        let fallback = URL(fileURLWithPath: "/tmp/fixture/fallback", isDirectory: true)
        #expect(
            ExtensionData.resolve(
                environment: ["EDITH_EXTENSION_DATA_ROOT": path], fallback: fallback) == fallback)
    }
}
