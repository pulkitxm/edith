import Foundation
import Testing

@testable import EdithKit

@Suite struct BlitzTreeClientTests {
    static let report = """
        {"schema_version":1,"tool":"blitztree","command":"quick-wins","read_only":true,
        "root":"/fixtures","scan_seconds":0.2,
        "summary":{"allocated_bytes":8192,"logical_bytes":7000,"file_count":2,"directory_count":1},
        "coverage":{"complete":false,"errors":1,"skipped_cloud_directories":2,"skipped_mount_points":1},
        "report":{"candidates":[],"candidate_count":0,"truncated":false,
        "inventory":{"largest_children":[{"path":"/fixtures/example","kind":"directory",
        "allocated_bytes":4096,"logical_bytes":3500,"file_count":1,"complete":false}],
        "largest_directories":[],"largest_files":[]}}}
        """

    @Test func partialCoverageAndUnlistedSpaceArePreserved() async throws {
        let client = BlitzTreeClient { arguments in
            #expect(
                arguments == [
                    "quick-wins", "--root", "/fixtures/quotes '; $(example)", "--limit", "200",
                ])
            return CLICommandResult(terminationStatus: 0, output: Self.report)
        }
        let report = try await client.scan(root: "/fixtures/quotes '; $(example)")
        #expect(!report.coverage.complete)
        #expect(report.coverage.errors == 1)
        #expect(report.coverage.skippedCloudDirectories == 2)
        #expect(report.unlistedBytes == 4096)
        #expect(report.report.inventory.largestChildren.first?.complete == false)
    }

    @Test func rejectsUnsupportedReports() async throws {
        for replacement in [
            ("\"schema_version\":1", "\"schema_version\":2"),
            ("\"tool\":\"blitztree\"", "\"tool\":\"other\""),
            ("\"read_only\":true", "\"read_only\":false"),
            ("\"command\":\"quick-wins\"", "\"command\":\"scan\""),
        ] {
            let output = Self.report.replacingOccurrences(of: replacement.0, with: replacement.1)
            let client = BlitzTreeClient { _ in
                CLICommandResult(terminationStatus: 0, output: output)
            }
            await #expect(throws: BlitzTreeError.invalidReport) {
                try await client.scan(root: "/fixtures")
            }
        }
    }

    @Test func surfacesStructuredErrors() async {
        let client = BlitzTreeClient { _ in
            CLICommandResult(
                terminationStatus: 1, output: "{\"error\":{\"message\":\"Cannot open folder\"}}")
        }
        await #expect(throws: BlitzTreeError.failed("Cannot open folder")) {
            try await client.scan(root: "/fixtures")
        }
    }

    @Test func invalidRootsNeverLaunch() async {
        let client = BlitzTreeClient { _ in
            Issue.record("Invalid roots must not launch a scan")
            return CLICommandResult(terminationStatus: 0, output: Self.report)
        }
        for root in ["", "relative", "/fixtures\0bad"] {
            await #expect(throws: BlitzTreeError.invalidRoot) { try await client.scan(root: root) }
        }
    }

    @Test func cargoInstallationUsesPinnedSourceAndVerifiesBinary() async throws {
        let installer = ToolInstaller { request, _ in
            switch request.arguments.first {
            case "cargo":
                if request.arguments != ["cargo", "--version"] {
                    #expect(request.arguments.contains("--locked"))
                    #expect(request.arguments.contains("d5a0fc8c30b150969f4c6066520f0cadc87a9eb6"))
                    #expect(request.arguments.suffix(3) == ["--bin", "blitztree", "blitztree"])
                }
                return CLICommandResult(terminationStatus: 0, output: "cargo")
            case "blitztree":
                #expect(request.arguments == ["blitztree", "--version"])
                return CLICommandResult(terminationStatus: 0, output: "1.0")
            default:
                Issue.record("Unexpected installer command")
                return CLICommandResult(terminationStatus: 1, output: "")
            }
        }
        #expect(try await installer.install(.blitzTree) == "1.0")
    }
}
