import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

private final class CLIHomebrewRecorder: @unchecked Sendable {
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

@Suite struct CLIHomebrewTests {
    @Test func statusReportsStableJSON() async {
        let result = await CLIProbe.runInWorld(["brew", "status", "--json"]) { _ in
            CLIEnvironment.homebrewClient = {
                HomebrewClient(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")) {
                    _, _ in CLICommandResult(terminationStatus: 0, output: "Homebrew 5.0.0\n")
                }
            }
        }

        #expect(result.code == 0)
        #expect(result.stderr.isEmpty)
        #expect(result.object?["available"] as? Bool == true)
        #expect(result.object?["executable"] as? String == "/opt/homebrew/bin/brew")
        #expect(result.object?["version"] as? String == "Homebrew 5.0.0")
    }

    @Test func listFiltersKindAndMergesUpdates() async throws {
        let recorder = CLIHomebrewRecorder()
        let result = await CLIProbe.runInWorld([
            "brew", "ls", "--kind", "formula", "--outdated", "--json",
        ]) { _ in
            CLIEnvironment.homebrewClient = {
                HomebrewClient(executableURL: URL(fileURLWithPath: "/brew")) { request, _ in
                    recorder.append(request)
                    return CLICommandResult(
                        terminationStatus: request.arguments.first == "outdated" ? 1 : 0,
                        output: request.arguments.first == "outdated"
                            ? Self.outdatedJSON : Self.infoJSON)
                }
            }
        }

        #expect(result.code == 0)
        #expect(result.stderr.isEmpty)
        let packages = try #require(result.array as? [[String: Any]])
        #expect(packages.count == 1)
        #expect(packages.first?["name"] as? String == "ripgrep")
        #expect(packages.first?["outdated"] as? Bool == true)
        #expect(
            recorder.requests.map(\.arguments) == [
                ["info", "--json=v2", "--installed"], ["outdated", "--json=v2"],
            ])
    }

    @Test func searchUsesTheSelectedKind() async throws {
        let recorder = CLIHomebrewRecorder()
        let result = await CLIProbe.runInWorld([
            "brew", "search", "fire", "--kind", "cask", "--json",
        ]) { _ in
            CLIEnvironment.homebrewClient = {
                HomebrewClient(executableURL: URL(fileURLWithPath: "/brew")) { request, _ in
                    recorder.append(request)
                    return CLICommandResult(
                        terminationStatus: 0,
                        output: request.arguments.first == "search" ? "firefox\n" : Self.caskJSON)
                }
            }
        }

        #expect(result.code == 0)
        let packages = try #require(result.array as? [[String: Any]])
        #expect(packages.first?["kind"] as? String == "cask")
        #expect(packages.first?["name"] as? String == "firefox")
        #expect(
            recorder.requests.map(\.arguments) == [
                ["search", "--cask", "fire"], ["info", "--json=v2", "--cask", "firefox"],
            ])
    }

    @Test func mutationsUseExactBoundedArguments() async {
        let recorder = CLIHomebrewRecorder()
        let result = await CLIProbe.runInWorld([
            "brew", "install", "firefox", "--kind", "cask", "--json",
        ]) { _ in
            CLIEnvironment.homebrewClient = {
                HomebrewClient(executableURL: URL(fileURLWithPath: "/brew")) { request, _ in
                    recorder.append(request)
                    return CLICommandResult(terminationStatus: 0, output: "installed firefox\n")
                }
            }
        }

        #expect(result.code == 0)
        #expect(result.object?["action"] as? String == "install")
        #expect(result.object?["changed"] as? Bool == true)
        #expect(recorder.requests.first?.arguments == ["install", "--cask", "firefox"])
        #expect(recorder.requests.first?.timeout == 1_800)
        #expect(recorder.requests.first?.terminatesProcessGroup == true)
    }

    @Test func uninstallPreviewsUntilConfirmed() async {
        let recorder = CLIHomebrewRecorder()
        await CLIProbe.inWorld { _ in
            CLIEnvironment.homebrewClient = {
                HomebrewClient(executableURL: URL(fileURLWithPath: "/brew")) { request, _ in
                    recorder.append(request)
                    return CLICommandResult(terminationStatus: 0, output: "uninstalled ripgrep\n")
                }
            }

            let preview = await CLIProbe.capture([
                "brew", "uninstall", "ripgrep", "--kind", "formula", "--json",
            ])
            #expect(preview.code == 0)
            #expect(preview.object?["applied"] as? Bool == false)
            #expect(preview.object?["changed"] as? Bool == false)
            #expect(recorder.requests.isEmpty)

            let applied = await CLIProbe.capture([
                "brew", "uninstall", "ripgrep", "--kind", "formula", "--yes", "--json",
            ])
            #expect(applied.code == 0)
            #expect(applied.object?["applied"] as? Bool == true)
            #expect(applied.object?["changed"] as? Bool == true)
            #expect(recorder.requests.first?.arguments == ["uninstall", "ripgrep"])
        }
    }

    @Test func invalidKindFailsBeforeHomebrewRuns() async {
        let recorder = CLIHomebrewRecorder()
        let result = await CLIProbe.runInWorld([
            "brew", "install", "ripgrep", "--kind", "bottle",
        ]) { _ in
            CLIEnvironment.homebrewClient = {
                HomebrewClient(executableURL: URL(fileURLWithPath: "/brew")) { request, _ in
                    recorder.append(request)
                    return CLICommandResult(terminationStatus: 0, output: "")
                }
            }
        }

        #expect(result.code == ExitCodes.usage)
        #expect(result.stderr.contains("use formula or cask"))
        #expect(recorder.requests.isEmpty)
    }

    private static let infoJSON = """
        {"formulae":[{"name":"ripgrep","versions":{"stable":"14.1.1"},"installed":[{"version":"14.1.0"}]}],"casks":[{"token":"firefox","name":["Firefox"],"version":"140.0","installed":"139.0"}]}
        """
    private static let outdatedJSON = """
        {"formulae":[{"name":"ripgrep","installed_versions":["14.1.0"],"current_version":"14.1.1"}],"casks":[]}
        """
    private static let caskJSON = """
        {"formulae":[],"casks":[{"token":"firefox","name":["Firefox"],"desc":"Browser","version":"140.0","installed":null}]}
        """
}
