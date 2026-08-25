import EdithKit
import Foundation
import Testing

@testable import Edith

private actor DockerDetailRunHarness {
    private var continuations: [CheckedContinuation<String, Never>?] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run() async -> Result<String, Error> {
        let output = await withCheckedContinuation { continuation in
            continuations.append(continuation)
            let ready = startWaiters.filter { continuations.count >= $0.0 }
            startWaiters.removeAll { continuations.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
        return .success(output)
    }

    func waitUntilStarted(_ count: Int) async {
        if continuations.count >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func resolve(_ index: Int, with output: String) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else {
            return
        }
        continuations[index] = nil
        continuation.resume(returning: output)
    }
}

private actor DockerDetailCommandHarness {
    private var inspectContinuation: CheckedContinuation<String, Never>?
    private var processStarted = false
    private var processWaiter: CheckedContinuation<Void, Never>?

    func run(_ command: String) async -> Result<String, Error> {
        if command.contains(" inspect ") {
            return .success(
                await withCheckedContinuation { inspectContinuation = $0 })
        }
        if command.contains(" top ") {
            processStarted = true
            processWaiter?.resume()
            processWaiter = nil
            return .success("PID USER %CPU %MEM RSS COMMAND\n2 root 0 0 1 ready")
        }
        return .failure(MachineDetailOperationError.invalidProcesses("unexpected"))
    }

    func waitForProcess() async {
        if processStarted { return }
        await withCheckedContinuation { processWaiter = $0 }
    }

    func resolveInspect(_ output: String) {
        inspectContinuation?.resume(returning: output)
        inspectContinuation = nil
    }
}

@Suite @MainActor struct DockerDetailGenerationTests {
    @Test func olderContainerInspectCannotReplaceTheCurrentContainer() async throws {
        let model = DockerDetailModel()
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let older = Self.container(id: "older")
        let current = Self.container(id: "current")
        let harness = DockerDetailRunHarness()

        model.startLogs(session: session, container: older)
        let first = Task {
            await model.loadInspect(container: older) { _, _ in await harness.run() }
        }
        await harness.waitUntilStarted(1)
        model.startLogs(session: session, container: current)
        await model.loadInspect(container: current) { _, _ in .success(Self.inspect("current")) }
        await harness.resolve(0, with: Self.inspect("older"))
        await first.value

        #expect(model.inspect?.image == "current")
        #expect(!model.inspectFailed)
    }

    @Test func olderProcessRetryCannotReplaceTheNewestResult() async throws {
        let model = DockerDetailModel()
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let container = Self.container(id: "api")
        let harness = DockerDetailRunHarness()

        model.startLogs(session: session, container: container)
        let first = Task {
            await model.loadProcesses(container: container) { _, _ in await harness.run() }
        }
        await harness.waitUntilStarted(1)
        await model.loadProcesses(container: container) { _, _ in
            .success(Self.process(pid: "2", command: "new"))
        }
        await harness.resolve(0, with: Self.process(pid: "1", command: "old"))
        await first.value

        #expect(model.processes.map(\.pid) == ["2"])
        #expect(model.processes.map(\.command) == ["new"])
        #expect(!model.processesFailed)
    }

    @Test func malformedProcessOutputClearsCachedRowsAndPublishesFailure() async {
        let model = DockerDetailModel()
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let container = Self.container(id: "api")
        model.startLogs(session: session, container: container)
        model.processes = [
            DockerProcess(pid: "1", user: "root", cpu: "0", memory: "0", command: "old")
        ]

        await model.loadProcesses(container: container) { _, _ in .success("invalid") }

        #expect(model.processes.isEmpty)
        #expect(model.processesFailed)
    }

    @Test func olderFileListingCannotReplaceTheCurrentContainer() async {
        let model = DockerDetailModel()
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let older = Self.container(id: "older")
        let current = Self.container(id: "current")
        let harness = DockerDetailRunHarness()

        model.startLogs(session: session, container: older)
        let first = Task {
            await model.loadFiles(container: older, path: "/") { _, _ in await harness.run() }
        }
        await harness.waitUntilStarted(1)
        model.startLogs(session: session, container: current)
        await model.loadFiles(container: current, path: "/") { _, _ in
            .success(Self.file(named: "current.txt"))
        }
        await harness.resolve(0, with: Self.file(named: "older.txt"))
        await first.value

        #expect(model.files.map(\.name) == ["current.txt"])
    }

    @Test func activeProcessesLoadWhileInspectIsStillPending() async {
        let model = DockerDetailModel()
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let container = Self.container(id: "api")
        let harness = DockerDetailCommandHarness()
        model.startLogs(session: session, container: container)

        let task = Task {
            await model.loadDetails(container: container, tab: .processes, filePath: "/") {
                command, _ in await harness.run(command)
            }
        }
        await harness.waitForProcess()
        for _ in 0..<20 where model.processes.isEmpty { await Task.yield() }

        #expect(model.processes.map(\.command) == ["ready"])
        #expect(model.inspect == nil)

        await harness.resolveInspect(Self.inspect("api"))
        await task.value
        #expect(model.inspect?.image == "api")
    }

    @Test func cancelledProcessAndFileLoadsCannotPublish() async {
        let model = DockerDetailModel()
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let container = Self.container(id: "api")
        model.startLogs(session: session, container: container)
        model.processes = [
            DockerProcess(pid: "1", user: "root", cpu: "0", memory: "0", command: "kept")
        ]
        model.files = FileListing.parse(output: Self.file(named: "kept.txt"), parent: "/")

        let processHarness = DockerDetailRunHarness()
        let processTask = Task {
            await model.loadProcesses(container: container) { _, _ in await processHarness.run() }
        }
        await processHarness.waitUntilStarted(1)
        processTask.cancel()
        await processHarness.resolve(0, with: Self.process(pid: "2", command: "replaced"))
        await processTask.value

        let fileHarness = DockerDetailRunHarness()
        let fileTask = Task {
            await model.loadFiles(container: container, path: "/next") { _, _ in
                await fileHarness.run()
            }
        }
        await fileHarness.waitUntilStarted(1)
        fileTask.cancel()
        await fileHarness.resolve(0, with: Self.file(named: "replaced.txt"))
        await fileTask.value

        #expect(model.processes.map(\.command) == ["kept"])
        #expect(model.files.map(\.name) == ["kept.txt"])
    }

    private static func container(id: String) -> DockerContainer {
        DockerContainer(
            id: id, names: [id], image: id, command: "", state: .running, status: "Up")
    }

    private static func inspect(_ image: String) -> String {
        """
        [{"Created":"today","Config":{"Image":"\(image)","Cmd":[],"Env":[],"Labels":{}},\
        "HostConfig":{"RestartPolicy":{"Name":"no"}},"Mounts":[],\
        "NetworkSettings":{"Networks":{}}}]
        """
    }

    private static func process(pid: String, command: String) -> String {
        "PID USER %CPU %MEM RSS COMMAND\n\(pid) root 0 0 1 \(command)"
    }

    private static func file(named name: String) -> String {
        "f\(FileListing.separator)1\(FileListing.separator)1\(FileListing.separator)644\(FileListing.separator)\(name)\(FileListing.separator)"
    }
}
