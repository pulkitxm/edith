import Foundation
import Testing

@testable import EdithKit

private final class HomebrewRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CLICommandRequest] = []

    func append(_ request: CLICommandRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }

    var requests: [CLICommandRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Suite struct HomebrewOperationsTests {
    private let installedJSON = """
        warning: using cached metadata {not-json}
        {"formulae":[{"name":"ripgrep","full_name":"ripgrep","desc":"Search text","homepage":"https://example.com/ripgrep","versions":{"stable":"14.1.1"},"installed":[{"version":"14.1.0"}]}],"casks":[{"token":"firefox","name":["Firefox"],"desc":"Browser","homepage":"https://example.com/firefox","version":"140.0","installed":"139.0"}]}
        warning after metadata {still-not-json}
        """

    private let outdatedJSON = """
        {"formulae":[{"name":"ripgrep","installed_versions":["14.1.0"],"current_version":"14.1.1","pinned":false}],"casks":[]}
        """

    @Test func parserFindsBoundedJSONBetweenWarnings() throws {
        let packages = try HomebrewParser.packages(from: installedJSON)

        #expect(packages.count == 2)
        #expect(packages.first { $0.name == "ripgrep" }?.installedVersion == "14.1.0")
        #expect(packages.first { $0.name == "firefox" }?.displayName == "Firefox")
    }

    @Test func parserAcceptsOutdatedCaskNameShape() throws {
        let output = """
            {"formulae":[],"casks":[{"name":"firefox","installed_versions":["139.0"],"current_version":"140.0"}]}
            """
        let package = try #require(HomebrewParser.packages(from: output, outdated: true).first)

        #expect(package.kind == .cask)
        #expect(package.name == "firefox")
        #expect(package.outdated)
    }

    @Test func installedPackagesMergeOutdatedMetadata() async throws {
        let client = HomebrewClient(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        ) { request, _ in
            CLICommandResult(
                terminationStatus: request.arguments.first == "outdated" ? 1 : 0,
                output: request.arguments.first == "outdated" ? outdatedJSON : installedJSON)
        }

        let packages = try await client.installed()
        let ripgrep = try #require(packages.first { $0.name == "ripgrep" })

        #expect(ripgrep.outdated)
        #expect(ripgrep.versionSummary == "14.1.0 to 14.1.1")
        #expect(packages.first?.name == "ripgrep")
    }

    @Test func searchUsesKindFlagAndCapsDetailLookup() async throws {
        let recorder = HomebrewRequestRecorder()
        let names = (0..<60).map { "tool\($0)" }.joined(separator: "\n")
        let client = HomebrewClient(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        ) { request, _ in
            recorder.append(request)
            if request.arguments.first == "search" {
                return CLICommandResult(terminationStatus: 0, output: names)
            }
            return CLICommandResult(terminationStatus: 0, output: "{\"formulae\":[],\"casks\":[]}")
        }

        _ = try await client.search("tool", kind: .formula)

        #expect(recorder.requests[0].arguments == ["search", "--formula", "tool"])
        #expect(recorder.requests[1].arguments.count == 43)
        #expect(recorder.requests[1].timeout == 60)
    }

    @Test func mutationIsNonInteractiveBoundedAndTerminatesItsProcessGroup() async throws {
        let recorder = HomebrewRequestRecorder()
        let client = HomebrewClient(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        ) { request, _ in
            recorder.append(request)
            return CLICommandResult(terminationStatus: 0, output: "installed\n")
        }

        let result = try await client.mutate(.install, kind: .cask, name: "firefox")
        let request = try #require(recorder.requests.first)

        #expect(result.name == "firefox")
        #expect(request.arguments == ["install", "--cask", "firefox"])
        #expect(request.environment["NONINTERACTIVE"] == "1")
        #expect(request.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(request.maximumOutputBytes == 2_000_000)
        #expect(request.timeout == 1_800)
        #expect(request.terminatesProcessGroup)
    }

    @Test func invalidPackageNeverStartsAProcess() async {
        let recorder = HomebrewRequestRecorder()
        let client = HomebrewClient(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        ) { request, _ in
            recorder.append(request)
            return CLICommandResult(terminationStatus: 0, output: "")
        }

        await #expect(throws: HomebrewFailure.invalidToken("--debug")) {
            try await client.mutate(.uninstall, kind: .formula, name: "--debug")
        }
        #expect(recorder.requests.isEmpty)
    }

    @Test func toolProvisioningTreatsHomebrewSetupAsManual() async throws {
        #expect(ToolProvisioning.spec(id: "homebrew") == .homebrew)
        await #expect(
            throws: ToolInstallFailure.manual(
                "Install Homebrew from https://brew.sh, then check again."
            )
        ) {
            try await ToolInstaller().install(.homebrew)
        }
    }
}
