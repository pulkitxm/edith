import Foundation
import Testing

@testable import DatabaseExtension
import EdithExtensionUI

@Suite struct DatabaseHelperSkeletonLoadingTests {
    @Test func databaseAndHelperHaveNoIndeterminateProgressViews() throws {
        for root in [
            packageRoot.appendingPathComponent("Views"),
        ] {
            for file in try swiftFiles(in: root) {
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(
                    source.range(
                        of: #"ProgressView\s*\(\s*\)"#,
                        options: .regularExpression) == nil,
                    "Indeterminate progress view remains in \(file.path)")
            }
        }
    }

    @Test func databaseLoadingSurfacesUseSkeletonReplicas() throws {
        let expectedSources = [
            "Views/DatabaseConnectionCreationSheet.swift",
            "Views/DatabaseConnectionGallery.swift",
            "Views/DatabaseConnectionManagementSheet.swift",
            "Views/DatabaseConnectionOverview.swift",
            "Views/DatabaseConnectionSidebar.swift",
            "Views/DatabaseObjectNavigatorView.swift",
            "Views/DatabasePage.swift",
            "Views/DatabaseSafetyReviewSheet.swift",
            "Views/DatabaseWorkbenchView.swift",
        ]

        for path in expectedSources {
            let source = try String(
                contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains("SkeletonReplica("), "Missing skeleton replica in \(path)")
        }
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftFiles(in root: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])
        else { return [] }

        return try enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            let values = try url.resourceValues(forKeys: Set(keys))
            return values.isRegularFile == true ? url : nil
        }
    }
}
