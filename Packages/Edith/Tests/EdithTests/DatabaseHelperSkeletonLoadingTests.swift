import Foundation
import Testing

@testable import EdithKit

@Suite struct DatabaseHelperSkeletonLoadingTests {
    @Test func databaseAndHelperHaveNoIndeterminateProgressViews() throws {
        for root in [
            packageRoot.appendingPathComponent("Sources/Edith/Features/Database"),
            packageRoot.appendingPathComponent("Sources/EdithHelper"),
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
            "Sources/Edith/Features/Database/Views/DatabaseConnectionCreationSheet.swift",
            "Sources/Edith/Features/Database/Views/DatabaseConnectionGallery.swift",
            "Sources/Edith/Features/Database/Views/DatabaseConnectionManagementSheet.swift",
            "Sources/Edith/Features/Database/Views/DatabaseConnectionOverview.swift",
            "Sources/Edith/Features/Database/Views/DatabaseConnectionSidebar.swift",
            "Sources/Edith/Features/Database/Views/DatabaseObjectNavigatorView.swift",
            "Sources/Edith/Features/Database/Views/DatabasePage.swift",
            "Sources/Edith/Features/Database/Views/DatabaseSafetyReviewSheet.swift",
            "Sources/Edith/Features/Database/Views/DatabaseWorkbenchView.swift",
        ]

        for path in expectedSources {
            let source = try String(
                contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains("SkeletonReplica("), "Missing skeleton replica in \(path)")
        }
    }

    @Test func cancelledDatabaseBrokerReadinessIsTerminal() async {
        let readiness = await DatabaseBrokerExtensionReadinessAdapter(
            ensureReady: { throw CancellationError() }
        ).readiness()

        #expect(readiness == .failed("The database service check was cancelled."))
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
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
