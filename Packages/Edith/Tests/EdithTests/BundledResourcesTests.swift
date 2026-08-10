import Foundation
import Testing

@testable import EdithKit

@Suite struct BundledResourcesTests {
    private func directories(app: String) -> [URL] {
        let bundle = URL(fileURLWithPath: app)
        return BundledResources.searchDirectories(
            mainBundleURL: bundle,
            mainResourceURL: bundle.appendingPathComponent("Contents/Resources"),
            ownerBundleURL: bundle,
            ownerResourceURL: bundle.appendingPathComponent("Contents/Resources"))
    }

    @Test func looksInsideTheAppResourcesDirectory() {
        let paths = directories(app: "/Applications/Edith.app").map(\.path)
        #expect(paths.contains("/Applications/Edith.app/Contents/Resources"))
    }

    @Test func looksBesideACommandLineToolInsideAnApp() {
        let tools = URL(fileURLWithPath: "/Applications/Edith.app/Contents/MacOS")
        let paths = BundledResources.searchDirectories(
            mainBundleURL: tools, mainResourceURL: tools, ownerBundleURL: tools,
            ownerResourceURL: tools
        ).map(\.path)
        #expect(paths.contains("/Applications/Edith.app/Contents/Resources"))
        #expect(paths.contains("/Applications/Edith.app/Contents/MacOS"))
    }

    @Test func dropsDuplicateDirectories() {
        let paths = directories(app: "/Applications/Edith.app").map(\.path)
        #expect(paths.count == Set(paths).count)
    }

    @Test func findsAFileInsideTheNamedBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let bundle = root.appendingPathComponent("Edith_EdithKit.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ok".utf8).write(to: bundle.appendingPathComponent("machine-collector.sh"))

        let found = BundledResources.locate(
            "machine-collector.sh", in: "Edith_EdithKit", directories: [root])
        #expect(found?.path == bundle.appendingPathComponent("machine-collector.sh").path)
    }

    @Test func returnsNilInsteadOfTrappingWhenTheBundleIsMissing() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(
            BundledResources.locate(
                "machine-collector.sh", in: "Edith_EdithKit", directories: [missing]) == nil)
    }

    @Test func resolvesTheCollectorScriptInThisBuild() {
        #expect(MachineCollector.script() != nil)
    }
}
