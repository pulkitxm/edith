import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@Suite struct ProductSkeletonLoadingTests {
    @Test func productViewsContainNoIndeterminateProgressViews() throws {
        let roots = [
            "AppMaintenance", "Attention", "Companion", "Dashboard", "Homebrew", "Pages",
            "Settings", "Onboarding",
        ]
        var violations: [String] = []

        for root in roots {
            let directory = featuresRoot.appendingPathComponent(root)
            for source in try swiftSources(in: directory) {
                let text = try String(contentsOf: source, encoding: .utf8)
                for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                where line.contains("ProgressView(") && !line.contains("value:") {
                    let path = source.path.replacingOccurrences(
                        of: sourcesRoot.path + "/", with: "")
                    violations.append("\(path):\(offset + 1)")
                }
            }
        }

        #expect(violations.isEmpty)
    }

    @Test @MainActor func runningAppsDistinguishesInitialLoadingFromLoadedEmpty() async {
        let model = RunningAppsModel(
            operations: RunningAppOperationCenter(snapshot: { [] }))

        #expect(!model.loaded)
        await model.refresh()
        #expect(model.loaded)
        #expect(!model.refreshing)
        #expect(model.apps.isEmpty)
    }

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private var featuresRoot: URL {
        sourcesRoot.appendingPathComponent("Edith/Features")
    }

    private func swiftSources(in directory: URL) throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]))
        return enumerator.compactMap { value in
            guard let url = value as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }
}
