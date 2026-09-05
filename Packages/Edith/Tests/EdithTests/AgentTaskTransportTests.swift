import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentTaskTransportTests {
    @Test func completionPublicationWakesWaitersBeforeTheirPollingDeadline() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let service = try AgentTaskService(
            directory: nil,
            publish: { snapshots in
                if let data = try? AgentPayload.encode(snapshots) {
                    await runtime.publish(topic: .tasks, payload: data)
                }
            })
        await service.register(operation: "fixture") { _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return Data("ready".utf8)
        }
        await AgentTaskOperations.register(on: runtime, service: service)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 2)
        let start = ContinuousClock.now
        let data = try await client.run(
            AgentTaskSubmission(operation: "fixture", title: "Push completion", payload: Data()))
        #expect(data == Data("ready".utf8))
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func processWorkFinishesAcrossAnXPCClientDisconnect() async throws {
        let service = try AgentTaskService(directory: nil)
        await service.registerCommand()
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let original = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 0.1; printf 'completed after disconnect\\n'"],
            environment: [:], timeout: 2, maximumOutputBytes: 1_024)
        let submission = AgentTaskSubmission(
            operation: AgentTaskOperation.command, title: "Disconnect fixture",
            payload: try AgentPayload.encode(request))
        let receipt = try await original.submit(submission)
        #expect(receipt.id == submission.id)
        original.client.reset()
        let replacement = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let data = try await replacement.wait(receipt.id)
        let result = try AgentPayload.decode(CLICommandResult.self, from: data)
        #expect(result.standardOutput == "completed after disconnect\n")
        #expect(try await replacement.status(receipt.id).snapshot.state == .succeeded)
    }

    @Test func commandCallbacksRetainEveryLineBeyondTheProgressRing() async throws {
        let service = try AgentTaskService(directory: nil)
        await service.registerCommand()
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let output = TaskTransportLines()
        let errors = TaskTransportLines()
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "i=0; while [ $i -lt 300 ]; do printf '%s\\n' \"$i\"; i=$((i + 1)); done; printf 'stderr\\n' >&2",
            ],
            environment: [:], timeout: 2, maximumOutputBytes: 8_192)
        let result = try await client.runCommand(
            request, onStandardOutputLine: { output.append($0) },
            onStandardErrorLine: { errors.append($0) })
        #expect(result.terminationStatus == 0)
        #expect(output.values == (0..<300).map(String.init))
        #expect(errors.values == ["stderr"])
    }

    @Test func commandTimeoutCrossesXPCAsItsOriginalErrorType() async throws {
        let service = try AgentTaskService(directory: nil)
        await service.registerCommand()
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["3"],
            environment: [:], timeout: 0.02)
        await #expect(throws: CLICommandRunnerError.timedOut) {
            _ = try await client.runCommand(
                request, onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
        }
    }

    @Test func cancellingTheClientTaskCancelsItsDaemonJob() async throws {
        let service = try AgentTaskService(directory: nil)
        await service.registerCommand()
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
            environment: [:], timeout: 6)
        let submission = AgentTaskSubmission(
            operation: AgentTaskOperation.command, title: "Cancel client fixture",
            payload: try AgentPayload.encode(request))
        let task = Task { try await client.run(submission) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while (try? await service.status(submission.id).snapshot.state) != .running,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        while (try? await service.status(submission.id).snapshot.state.isTerminal) != true,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await service.status(submission.id).snapshot.state == .cancelled)
    }
}

private final class TaskTransportLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var values: [String] { lock.withLock { lines } }
    func append(_ value: String) { lock.withLock { lines.append(value) } }
}

private final class TaskTestListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    private let service: AgentTaskService

    init(service: AgentTaskService) {
        self.service = service
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func client() -> AgentClient {
        AgentClient(connectionFactory: { [self] disconnected, _ in
            TaskTestConnection(endpoint: listener.endpoint, disconnected: disconnected)
        })
    }

    func stop() { listener.invalidate() }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
        -> Bool
    {
        connection.exportedInterface = NSXPCInterface(with: EdithAgentXPC.self)
        connection.exportedObject = TaskTestPeer(service: service)
        connection.resume()
        return true
    }
}

private final class TaskTestConnection: AgentClientConnection, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(endpoint: NSXPCListenerEndpoint, disconnected: @escaping @Sendable () -> Void) {
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: EdithAgentXPC.self)
        connection.invalidationHandler = disconnected
        connection.interruptionHandler = disconnected
        connection.resume()
    }

    func remote(onError: @escaping @Sendable (Error) -> Void) throws -> EdithAgentXPC {
        guard let remote = connection.remoteObjectProxyWithErrorHandler(onError) as? EdithAgentXPC
        else { throw AgentError.unavailable }
        return remote
    }

    func invalidate() { connection.invalidate() }
}

private final class TaskTestPeer: NSObject, EdithAgentXPC, @unchecked Sendable {
    private let service: AgentTaskService
    init(service: AgentTaskService) { self.service = service }

    func handshake(peerVersion: Int, reply: @escaping (Data?, String?) -> Void) {
        reply(
            try? AgentPayload.encode(
                AgentHandshake(
                    protocolVersion: AgentService.protocolVersion, build: "fixture",
                    startedAt: Date())), nil)
    }

    func snapshot(topic: String, reply: @escaping (Data?, String?) -> Void) {
        reply(nil, "No fixture snapshot.")
    }
    func subscribe(topic: String, reply: @escaping (String?) -> Void) { reply(nil) }
    func unsubscribe(topic: String, reply: @escaping (String?) -> Void) { reply(nil) }

    func perform(operation: String, payload: Data, reply: @escaping (Data?, String?) -> Void) {
        Task {
            do {
                let data: Data
                switch operation {
                case AgentTaskOperation.submit:
                    let request = try AgentPayload.decode(AgentTaskSubmission.self, from: payload)
                    data = try await AgentPayload.encode(service.submit(request))
                case AgentTaskOperation.status:
                    let request = try AgentPayload.decode(AgentTaskIDRequest.self, from: payload)
                    data = try await AgentPayload.encode(service.status(request.id))
                case AgentTaskOperation.cancel:
                    let request = try AgentPayload.decode(AgentTaskIDRequest.self, from: payload)
                    data = try await AgentPayload.encode(service.cancel(request.id))
                default:
                    data = try await AgentPayload.encode(service.snapshots())
                }
                reply(data, nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }
}
