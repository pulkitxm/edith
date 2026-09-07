import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
private func waitForHomebrewModel(
    timeout: Duration = .seconds(3), _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
@Suite struct HomebrewPageModelTests {
    @Test func activationLoadsInstalledPackagesAndUpdates() async {
        let model = HomebrewPageModel(client: Self.client())

        model.activate(kind: .formula)
        #expect(await waitForHomebrewModel { model.loaded })

        #expect(model.status?.available == true)
        #expect(model.packages.map(\.name) == ["ripgrep"])
        #expect(model.packages.first?.outdated == true)
        #expect(model.installedCount == 1)
        #expect(model.updateCount == 1)
    }

    @Test func searchAndInstallRefreshTheDiscoveryResults() async throws {
        let recorder = CLIHomebrewModelRecorder()
        let model = HomebrewPageModel(client: Self.client(recorder: recorder))

        model.search("fire", kind: .cask)
        #expect(await waitForHomebrewModel { model.loaded })
        let package = try #require(model.packages.first)
        #expect(package.name == "firefox")
        #expect(!package.installed)

        model.perform(.install, package: package, query: "fire", kind: .cask)
        #expect(await waitForHomebrewModel { !model.isBusy && model.resultMessage != nil })

        #expect(model.resultMessage == "Installed Firefox.")
        #expect(recorder.requests.contains { $0.arguments == ["install", "--cask", "firefox"] })
        #expect(recorder.requests.filter { $0.arguments.first == "search" }.count == 2)
    }

    @Test func cancellationClearsBusyStateAndReportsOutcome() async {
        let model = HomebrewPageModel(
            client: HomebrewClient(executableURL: URL(fileURLWithPath: "/brew")) { request, _ in
                if request.arguments.first == "install" {
                    try await Task.sleep(for: .seconds(30))
                }
                return CLICommandResult(terminationStatus: 0, output: "")
            })
        let package = HomebrewPackage(
            kind: .formula, name: "ripgrep", displayName: "ripgrep")

        model.perform(.install, package: package, query: "", kind: .formula)
        #expect(model.isBusy)
        model.cancel()
        #expect(await waitForHomebrewModel { !model.isBusy })

        #expect(model.resultMessage == "Homebrew operation cancelled.")
        #expect(!model.isCancelling)
    }

    private static func client(
        recorder: CLIHomebrewModelRecorder? = nil
    ) -> HomebrewClient {
        HomebrewClient(executableURL: URL(fileURLWithPath: "/brew")) { request, _ in
            recorder?.append(request)
            switch request.arguments.first {
            case "--version":
                return CLICommandResult(terminationStatus: 0, output: "Homebrew 5.0.0\n")
            case "outdated":
                return CLICommandResult(terminationStatus: 0, output: outdatedJSON)
            case "search":
                return CLICommandResult(terminationStatus: 0, output: "firefox\n")
            case "info" where request.arguments.contains("--cask"):
                return CLICommandResult(terminationStatus: 0, output: caskJSON)
            case "info":
                return CLICommandResult(terminationStatus: 0, output: infoJSON)
            default:
                return CLICommandResult(terminationStatus: 0, output: "completed\n")
            }
        }
    }

    nonisolated private static let infoJSON = """
        {"formulae":[{"name":"ripgrep","versions":{"stable":"14.1.1"},"installed":[{"version":"14.1.0"}]}],"casks":[]}
        """
    nonisolated private static let outdatedJSON = """
        {"formulae":[{"name":"ripgrep","installed_versions":["14.1.0"],"current_version":"14.1.1"}],"casks":[]}
        """
    nonisolated private static let caskJSON = """
        {"formulae":[],"casks":[{"token":"firefox","name":["Firefox"],"desc":"Browser","version":"140.0","installed":null}]}
        """
}

private final class CLIHomebrewModelRecorder: @unchecked Sendable {
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
