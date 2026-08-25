import Foundation
import Testing

@testable import EdithKit

private actor SnippetCancellationGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite struct MachineDetailOperationTests {
    @Test func descriptorsAreUniqueReadOnlyAndComplete() {
        let details = DockerDetailOperation.allCases.map(\.descriptor)
        let snippets = SavedSnippetOperation.allCases.map(\.descriptor)
        #expect(
            details.map(\.cli) == [
                ["machines", "docker", "inspect"], ["machines", "docker", "top"],
            ])
        #expect(details.allSatisfy { $0.effect == .read })
        #expect(snippets.map(\.cli) == [["machines", "snippets", "run"]])
        #expect(snippets.first?.effect == .interactive)
        #expect(Set((details + snippets).map(\.id)).count == details.count + snippets.count)
    }

    @Test func inspectUsesTheSharedCommandTimeoutAndParser() async throws {
        var command = ""
        var timeout: TimeInterval = 0
        let result = await DockerDetailOperationExecution.inspect(containerID: "api service") {
            next, seconds in
            command = next
            timeout = seconds
            return .success(Self.inspectJSON)
        }
        let summary = try result.get()
        #expect(command == DockerCommands.inspectRaw("api service"))
        #expect(timeout == 30)
        #expect(summary.image == "example/api:latest")
        #expect(summary.networks == ["backend"])
    }

    @Test func malformedInspectIsAStableFailure() async {
        let result = await DockerDetailOperationExecution.inspect(containerID: "missing") { _, _ in
            .success("not json")
        }
        guard case let .failure(error) = result else {
            Issue.record("Expected malformed inspect output to fail")
            return
        }
        #expect(error as? MachineDetailOperationError == .invalidInspect("missing"))
    }

    @Test func topUsesTheSharedCommandTimeoutAndPreservesProcessOrder() async throws {
        var command = ""
        var timeout: TimeInterval = 0
        let result = await DockerDetailOperationExecution.processes(containerID: "api") {
            next, seconds in
            command = next
            timeout = seconds
            return .success(
                "PID USER %CPU %MEM RSS COMMAND\n12 root 2.1 1.0 20 server\n7 app 0.2 0.4 10 worker"
            )
        }
        let rows = try result.get()
        #expect(command == DockerCommands.top("api"))
        #expect(timeout == 30)
        #expect(rows.map(\.pid) == ["12", "7"])
        #expect(rows.map(\.command) == ["server", "worker"])
    }

    @Test func malformedTopIsAStableFailure() async {
        let result = await DockerDetailOperationExecution.processes(containerID: "api") { _, _ in
            .success("unexpected")
        }
        guard case let .failure(error) = result else {
            Issue.record("Expected malformed process output to fail")
            return
        }
        #expect(error as? MachineDetailOperationError == .invalidProcesses("api"))
    }

    @Test func browserResolutionSharesContainerAndPortSelection() throws {
        let container = Self.container
        #expect(
            try DockerBrowserOperationExecution.container(named: "abc123000000", in: [container])
                == container)
        #expect(
            try DockerBrowserOperationExecution.publishedPort(in: container, matching: 80)
                .hostPort == 8080)
        #expect(
            DockerBrowserOperationExecution.url(for: container.ports[0])?.absoluteString
                == "http://localhost:8080")
        #expect(
            DockerBrowserOperationExecution.url(
                for: container.ports[0], host: "box.example")?.absoluteString
                == "http://box.example:8080")
        #expect(
            DockerBrowserOperationExecution.url(
                for: container.ports[0], host: "2001:db8::1")?.absoluteString
                == "http://[2001:db8::1]:8080")
        #expect(
            DockerBrowserOperationExecution.url(
                for: container.ports[0], host: "box.example/path") == nil)
        #expect(throws: MachineDetailOperationError.self) {
            try DockerBrowserOperationExecution.publishedPort(in: container, matching: nil)
        }
    }

    @Test func savedSnippetSelectionAndExecutionUseStoredCommand() async throws {
        let snippets = [
            CommandSnippet(machineID: UUID(), title: "Logs", command: "journalctl -xe"),
            CommandSnippet(machineID: nil, title: "Disk", command: "df -h"),
        ]
        let snippet = try SavedSnippetOperationExecution.snippet(at: 2, in: snippets)
        var command = ""
        var timeout: TimeInterval = 0
        let result = await SavedSnippetOperationExecution.run(snippet) { next, seconds in
            command = next
            timeout = seconds
            return .success("ok")
        }
        #expect(try result.get() == "ok")
        #expect(command == "df -h")
        #expect(timeout == 120)
        #expect(throws: MachineDetailOperationError.self) {
            try SavedSnippetOperationExecution.snippet(at: 3, in: snippets)
        }
    }

    @Test func savedSnippetExecutionPropagatesCancellation() async {
        let gate = SnippetCancellationGate()
        let snippet = CommandSnippet(title: "Wait", command: "sleep 30")
        let task = Task {
            await SavedSnippetOperationExecution.run(snippet) { _, _ in
                await gate.markStarted()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return .success("late")
                } catch {
                    return .failure(error)
                }
            }
        }
        await gate.waitUntilStarted()
        task.cancel()
        let result = await task.value
        guard case let .failure(error) = result else {
            Issue.record("Expected cancellation to reach the snippet runner")
            return
        }
        #expect(error is CancellationError)
    }

    private static let container = DockerContainer(
        id: "abc123000000", names: ["api"], image: "api", command: "", state: .running,
        status: "Up",
        ports: [
            DockerPortMapping(
                hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: "tcp"),
            DockerPortMapping(
                hostIP: "0.0.0.0", hostPort: 8443, containerPort: 443, proto: "tcp"),
        ])

    private static let inspectJSON = """
        [{"Created":"2026-08-23T10:00:00Z","Config":{"Image":"example/api:latest",\
        "Cmd":["serve"],"Env":["PORT=8080"],"Labels":{}},"HostConfig":{"RestartPolicy":\
        {"Name":"always"}},"Mounts":[],"NetworkSettings":{"Networks":{"backend":{}}}}]
        """
}
