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

    @Test func browserResolutionHonorsBindScopeAndSSHConfigHosts() {
        let wildcardIPv4 = DockerPortMapping(
            hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: "tcp")
        let wildcardIPv6 = DockerPortMapping(
            hostIP: "[::]", hostPort: 8081, containerPort: 81, proto: "tcp")
        let specificIPv4 = DockerPortMapping(
            hostIP: "192.0.2.8", hostPort: 8082, containerPort: 82, proto: "tcp")
        let specificIPv6 = DockerPortMapping(
            hostIP: "[2001:db8::8]", hostPort: 8083, containerPort: 83, proto: "tcp")
        let loopbackIPv4 = DockerPortMapping(
            hostIP: "127.0.0.1", hostPort: 8084, containerPort: 84, proto: "tcp")
        let loopbackIPv6 = DockerPortMapping(
            hostIP: "[::1]", hostPort: 8085, containerPort: 85, proto: "tcp")

        #expect(
            DockerBrowserOperationExecution.url(for: wildcardIPv4, host: "box.example")?
                .absoluteString == "http://box.example:8080")
        #expect(
            DockerBrowserOperationExecution.url(for: wildcardIPv6, host: "box.example")?
                .absoluteString == "http://box.example:8081")
        #expect(
            DockerBrowserOperationExecution.url(for: specificIPv4, host: "box.example")?
                .absoluteString == "http://192.0.2.8:8082")
        #expect(
            DockerBrowserOperationExecution.url(for: specificIPv6, host: "box.example")?
                .absoluteString == "http://[2001:db8::8]:8083")
        #expect(DockerBrowserOperationExecution.url(for: loopbackIPv4, host: "box.example") == nil)
        #expect(DockerBrowserOperationExecution.url(for: loopbackIPv6, host: "box.example") == nil)
        #expect(
            DockerBrowserOperationExecution.url(for: loopbackIPv4)?.absoluteString
                == "http://127.0.0.1:8084")

        let machine = Machine(
            name: "Box", host: "", source: .sshConfigAlias("box-alias"))
        let config = [SSHConfigHost(alias: "box-alias", hostName: "box.example")]
        #expect(
            DockerBrowserOperationExecution.browserHost(for: machine, configHosts: config)
                == "box.example")
        #expect(
            DockerBrowserOperationExecution.url(
                for: wildcardIPv4, machine: machine, configHosts: config)?.absoluteString
                == "http://box.example:8080")
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
