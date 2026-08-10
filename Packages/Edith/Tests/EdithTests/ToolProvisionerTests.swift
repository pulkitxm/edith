import Foundation
import Observation
import Testing

@testable import EdithKit

private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CLICommandRequest] = []

    func record(_ request: CLICommandRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return requests.filter { $0.arguments == request.arguments }.count
    }

    func count(where predicate: (CLICommandRequest) -> Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter(predicate).count
    }
}

@MainActor
@Suite struct ToolProvisionerTests {
    private let tool = CLIToolSpec(
        id: "test-tool", displayName: "Test Tool", why: "Supports the test feature.",
        presenceStrategy: .executable(name: "test-tool", versionArguments: ["--version"]),
        installStrategy: .packageManagers(
            homebrewArguments: ["install", "--cask", "test-tool"],
            npmPackage: "@example/test-tool", instruction: "Install Test Tool manually."))

    @Test func presenceCheckShortCircuitsInstallation() async {
        let recorder = CommandRecorder()
        let provisioner = ToolProvisioner { request, onLine in
            recorder.record(request)
            onLine("1.2.3")
            return CLICommandResult(terminationStatus: 0, output: "1.2.3\n")
        }

        await provisioner.provision(tool).value

        #expect(provisioner.state(for: tool) == .present(version: "1.2.3"))
        #expect(recorder.count { $0.arguments == ["test-tool", "--version"] } == 1)
        #expect(recorder.count { $0.arguments.contains("install") } == 0)
    }

    @Test func successfulInstallTransitionsThroughExpectedStates() async {
        let recorder = CommandRecorder()
        let provisioner = ToolProvisioner { request, onLine in
            let occurrence = recorder.record(request)
            if request.arguments == ["test-tool", "--version"] {
                if occurrence == 1 {
                    return CLICommandResult(terminationStatus: 127, output: "")
                }
                onLine("2.0.0")
                return CLICommandResult(terminationStatus: 0, output: "2.0.0\n")
            }
            if request.arguments == ["brew", "--version"] {
                return CLICommandResult(terminationStatus: 0, output: "Homebrew 5\n")
            }
            onLine("installed")
            return CLICommandResult(terminationStatus: 0, output: "installed\n")
        }
        var transitions: [CLIToolProvisionState] = []
        var observing = true
        func observeStates() {
            withObservationTracking {
                _ = provisioner.states
            } onChange: {
                Task { @MainActor in
                    guard observing else { return }
                    if let state = provisioner.states[self.tool.id] {
                        transitions.append(state)
                        switch state {
                        case .installed, .failed:
                            observing = false
                            return
                        default:
                            break
                        }
                    }
                    observeStates()
                }
            }
        }
        observeStates()

        await provisioner.provision(tool).value
        for _ in 0..<10 { await Task.yield() }

        let checking = transitions.firstIndex(of: .checking)
        let installing = transitions.firstIndex {
            if case .installing = $0 { return true }
            return false
        }
        let installed = transitions.firstIndex(of: .installed)
        #expect(checking != nil)
        #expect(installing != nil)
        #expect(installed != nil)
        #expect(checking! < installing!)
        #expect(installing! < installed!)
    }

    @Test func failureCarriesManualInstruction() async {
        let provisioner = ToolProvisioner { _, _ in
            CLICommandResult(terminationStatus: 127, output: "")
        }

        await provisioner.provision(tool).value

        guard case let .failed(message, instruction) = provisioner.state(for: tool) else {
            Issue.record("Expected failed state")
            return
        }
        #expect(message.contains("Neither Homebrew nor npm"))
        #expect(instruction == "Install Test Tool manually.")
    }

    @Test func onlyOneInstallRunsPerToolAtATime() async {
        let recorder = CommandRecorder()
        let provisioner = ToolProvisioner { request, _ in
            let occurrence = recorder.record(request)
            if request.arguments == ["test-tool", "--version"] {
                return CLICommandResult(
                    terminationStatus: occurrence == 1 ? 127 : 0,
                    output: occurrence == 1 ? "" : "3.0.0\n")
            }
            if request.arguments == ["brew", "--version"] {
                return CLICommandResult(terminationStatus: 0, output: "Homebrew 5\n")
            }
            await Task.yield()
            return CLICommandResult(terminationStatus: 0, output: "installed\n")
        }

        let first = provisioner.provision(tool)
        let second = provisioner.provision(tool)
        await first.value
        await second.value

        #expect(
            recorder.count {
                $0.arguments == ["brew", "install", "--cask", "test-tool"]
            } == 1)
    }
}
