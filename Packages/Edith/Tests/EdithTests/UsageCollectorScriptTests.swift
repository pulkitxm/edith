import Foundation
import Testing

@testable import EdithKit

@Suite struct UsageCollectorScriptTests {
    @Test(arguments: [
        ("usage-billing-archive.mjs", "BILLING_ARCHIVE_SCRIPT"),
        ("usage-session-input.mjs", "SESSION_INPUT_SCRIPT"),
    ])
    func remotePayloadCreatesItsExactBundledRuntime(name: String, variable: String) async throws {
        let script = try #require(UsageCollector.script())
        let text = try #require(String(data: script, encoding: .utf8))
        let boundary = try #require(text.range(of: "\n_now() {"))
        let prefix = String(text[..<boundary.lowerBound])
        let runtimeURL = try #require(
            BundledResources.locate(name, in: BundledResources.kitBundleName)
        )
        let expected = try Data(contentsOf: runtimeURL)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-collector-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["EDITH_CACHE_DIR"] = root.appendingPathComponent("cache").path
        environment["TMPDIR"] = root.path
        let result = try await CLICommandRunner.run(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-s", "--", root.appendingPathComponent("data").path],
                environment: environment, currentDirectoryURL: root,
                timeout: 5, maximumOutputBytes: 256 * 1_024,
                standardInputData: Data((prefix + "\ncat \"$\(variable)\"\n").utf8),
                terminatesProcessGroup: true),
            onLine: { _ in })
        #expect(result.terminationStatus == 0)
        #expect(result.standardOutputData == expected)
    }
}
