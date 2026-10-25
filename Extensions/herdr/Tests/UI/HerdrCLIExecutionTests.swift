import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing
@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrCLIExecutionTests {
    @Test func originalSpaceCLIUsesRetainedEngineModelsAndAuthenticatedFocus() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = makeWorker()
        let agents = ["Desk", "Other"].enumerated().map { index, workspace in
            HerdrAgent.make(
                machineID: "local", machineName: "Synthetic Mac", machineIsLocal: true,
                sshTarget: nil, session: "fixture", pane: "p\(index)", kind: "Synthetic tool",
                status: .working, title: workspace, workspace: workspace, cwd: "/tmp/fixture")
        }
        worker.store.hosts = [
            .init(
                id: "local", name: "Synthetic Mac", isLocal: true,
                herdrPresent: true, reachable: true, agents: agents)
        ]
        let groups = HerdrAgentSpace.group(agents)
        var presentations: [HerdrUIPresentation] = []
        for group in groups {
            let value = try JSONDecoder().decode(
                HerdrUIPresentation.self,
                from: await worker.execute(
                    "herdr.ui.present",
                    payload: JSONSerialization.data(withJSONObject: [
                        "kind": "space", "id": group.id,
                    ])))
            presentations.append(value)
        }
        #expect(worker.spaces.listed().isEmpty)
        for value in presentations {
            _ = try await worker.execute(
                "herdr.ui.presentation.admit",
                payload: JSONSerialization.data(
                    withJSONObject: ["token": value.token.uuidString]))
        }
        let missing = try await HerdrCLIExecution.run(
            ExtensionCLIRequest(arguments: ["space", "terminal"]), worker: worker)
        #expect(
            missing.exitCode != 0 && missing.stderr.contains("more than one space window is open"))
        let desk = try #require(presentations.first { $0.title == "Desk" })
        _ = try await worker.execute(
            "herdr.ui.presentation.focus",
            payload: JSONSerialization.data(
                withJSONObject: ["token": desk.token.uuidString, "key": true]))
        let terminal = try await HerdrCLIExecution.run(
            ExtensionCLIRequest(arguments: ["space", "terminal", "--json"]), worker: worker)
        #expect(
            terminal.exitCode == 0 && terminal.stderr.isEmpty
                && terminal.stdout.contains("opened a terminal"))
        #expect(worker.spaces.listed().first { $0.title == "Desk" }?.tabs == 2)
        let split = try await HerdrCLIExecution.run(
            ExtensionCLIRequest(arguments: [
                "space", "split", "--window", "desk", "--side", "down", "--json",
            ]), worker: worker)
        #expect(split.exitCode == 0 && split.stdout.contains("split bottom"))
        #expect(worker.spaces.listed().first { $0.title == "Desk" }?.panes == 3)
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "herdr.ui.presentation.close",
                payload: JSONSerialization.data(withJSONObject: ["token": UUID().uuidString]))
        }
        _ = try await worker.execute(
            "herdr.ui.presentation.close",
            payload: JSONSerialization.data(withJSONObject: ["token": desk.token.uuidString]))
        #expect(worker.spaces.listed().count == 1)
        await worker.shutdown()
        #expect(worker.spaces.listed().isEmpty)
    }

    @Test func ownedStreamsExecuteOriginalCommandsWithRetainedOwnerContext() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = makeWorker()
        let request = try ExtensionCLIRequest(
            arguments: ["layout", "ls", "--json"],
            standardInput: Data("synthetic input".utf8), workingDirectory: "/private/tmp",
            interactive: false)
        let data = try JSONEncoder().encode(
            ExtensionCLIStreamStart(
                owner: "herdr", session: UUID(), request: request, deadline: 5))
        let handle = try JSONDecoder().decode(
            ExtensionCLIStreamHandle.self,
            from: await worker.execute("herdr.cli.start", payload: data))
        var cursor: UInt64 = 0
        var output = Data()
        var errors = Data()
        var exit: Int32?
        for _ in 0..<100 {
            let frame = try JSONDecoder().decode(
                ExtensionCLIStreamFrame.self,
                from: await worker.execute(
                    "herdr.cli.read",
                    payload: JSONEncoder().encode(
                        ExtensionCLIStreamRead(handle: handle, sequence: cursor))))
            try frame.validate()
            cursor = frame.nextSequence
            for chunk in frame.chunks {
                if chunk.channel == .stdout {
                    output.append(chunk.data)
                } else {
                    errors.append(chunk.data)
                }
            }
            if let code = frame.exitCode { exit = code; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(exit == 0 && errors.isEmpty)
        #expect(String(decoding: output, as: UTF8.self).contains("arrangements"))
        let wrong = ExtensionCLIStreamHandle(owner: "herdr", session: handle.session, token: UUID())
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("herdr.cli.end", payload: JSONEncoder().encode(wrong))
        }
        _ = try await worker.execute("herdr.cli.end", payload: JSONEncoder().encode(handle))
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "herdr.cli.read",
                payload: JSONEncoder().encode(
                    ExtensionCLIStreamRead(handle: handle, sequence: cursor)))
        }
        #expect(HerdrCLIEnvironment.context == nil && ExtensionCLIContext.request == nil)
    }

    @Test func liveCatalogPublishesOriginalLeafRoutesAndWithdrawsWithOwner() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = makeWorker()
        let data = try await worker.execute("herdr.cli.catalog", payload: Data("{}".utf8))
        let value = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(value["owner"] as? String == "herdr" && value["version"] as? Int == 1)
        let commands = try #require(value["commands"] as? [[String: Any]])
        let routes = commands.compactMap { $0["route"] as? [String] }
        #expect(routes.contains(["herdr", "layout", "ls"]))
        #expect(Set(routes.map { $0.joined(separator: " ") }).count == routes.count)
        #expect(
            commands.allSatisfy {
                $0["operation"] as? String == "herdr.cli"
                    && $0["streamOperation"] as? String == "herdr.cli"
            })
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("herdr.cli.catalog", payload: Data("{}".utf8))
        }
    }

    @Test func originalMachineSelectorsAcceptSavedIDsNamesTargetsAndUnambiguousPrefixes() throws {
        let first = Machine(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Build one", host: "fixture-one")
        let second = Machine(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            name: "Build two", host: "fixture-two")
        let machines = [first, second]
        for query in [first.id.uuidString.lowercased(), "1000", "build ONE", "fixture-one"] {
            #expect(try MachineResolver.machine(query, in: machines) == first)
        }
        for query in ["build", "fixture", "missing", ""] {
            #expect(throws: CLIFailure.self) { try MachineResolver.machine(query, in: machines) }
        }
    }

    @Test func originalListCommandRendersOwnedInventoryAndPreservesFailureStreams() async throws {
        defer { HerdrWorkOwnership.enable() }
        let previous = HerdrCLIEnvironment.collect
        HerdrCLIEnvironment.collect = { _ in
            [
                .init(
                    id: "local", name: "Synthetic", isLocal: true,
                    herdrPresent: true, reachable: true,
                    agents: [
                        .make(
                            machineID: "local", machineName: "Synthetic",
                            machineIsLocal: true, sshTarget: nil, session: "mock", pane: "p1",
                            kind: "Synthetic",
                            status: .working, title: "Example", workspace: "mock", cwd: "/tmp/mock")
                    ])
            ]
        }
        defer { HerdrCLIEnvironment.collect = previous }
        let worker = makeWorker()
        let reply = try await HerdrCLIExecution.run(
            .init(arguments: ["ls", "--json"]), worker: worker)
        #expect(reply.exitCode == 0 && reply.stderr.isEmpty)
        let value = try #require(
            try JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any])
        #expect((value["agents"] as? [[String: Any]])?.first?["pane"] as? String == "p1")
        let missing = try await HerdrCLIExecution.run(
            .init(arguments: ["command", "missing"]), worker: worker)
        #expect(
            missing.exitCode == 3 && missing.stdout.isEmpty
                && missing.stderr.contains("no herdr pane"))
        let invalid = try await HerdrCLIExecution.run(
            .init(arguments: ["send", "p1", "hello", "--in", "invalid"]), worker: worker)
        #expect(invalid.exitCode == 2 && invalid.stdout.isEmpty && invalid.stderr.contains("--in"))
        await worker.shutdown()
    }

    @Test func originalLayoutsOperateOnOwnStoreAndDisabledOwnerCannotExecute() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = makeWorker()
        let reply = try await HerdrCLIExecution.run(
            .init(arguments: ["layout", "ls", "--json"]), worker: worker)
        #expect(reply.exitCode == 0 && reply.stderr.isEmpty)
        #expect(reply.stdout.contains("arrangements") && reply.stdout.contains("board"))
        let failure = try await HerdrCLIExecution.run(
            .init(arguments: ["close-tab", "missing", "--json"]), worker: worker)
        #expect(failure.exitCode != 0 && failure.stdout.isEmpty)
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await HerdrCLIExecution.run(.init(arguments: ["layout", "ls"]), worker: worker)
        }
    }

    @Test func originalScheduledMessageCommandsPersistAndCancelOwningHooks() async throws {
        defer { HerdrWorkOwnership.enable() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = HerdrAgent.make(
            machineID: "local", machineName: "Synthetic", machineIsLocal: true,
            sshTarget: nil, session: "mock", pane: "p1", kind: "claude", status: .working,
            title: "Example", workspace: "mock", cwd: root.path, stateSequence: 4)
        let previous = HerdrCLIEnvironment.collect
        HerdrCLIEnvironment.collect = { _ in
            [
                .init(
                    id: "local", name: "Synthetic", isLocal: true, herdrPresent: true,
                    reachable: true, agents: [agent])
            ]
        }
        defer { HerdrCLIEnvironment.collect = previous }
        let hooks = AgentHookService(
            url: root.appendingPathComponent("hooks.json"),
            armProbe: { agent in
                .agent(
                    .init(
                        kind: agent.kind, status: agent.status, sequence: agent.stateSequence,
                        identity: .init(terminalID: "fixture-terminal", processGroupID: 123)))
            })
        let suite = "herdr.cli.fixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let worker = HerdrWorker(
            store: HerdrStore(defaults: defaults, machinesProvider: { [] }), defaults: defaults,
            hooks: hooks, automaticActions: false)
        let armed = try await HerdrCLIExecution.run(
            .init(arguments: ["send", "p1", "resume the fixture", "--when-finished", "--json"]),
            worker: worker)
        #expect(armed.exitCode == 0 && armed.stderr.isEmpty)
        let hook = try #require(await hooks.list().hooks.first)
        #expect(hook.message == "resume the fixture" && hook.schedule == .whenFinished)
        let persisted = try AgentPayload.decode(
            HerdrHooksSnapshot.self,
            from: Data(contentsOf: root.appendingPathComponent("hooks.json")))
        #expect(persisted.hooks.first?.id == hook.id)
        let listed = try await HerdrCLIExecution.run(
            .init(arguments: ["hooks", "ls", "--json"]), worker: worker)
        #expect(listed.exitCode == 0 && listed.stdout.contains(hook.id.uuidString))
        let conflict = try await HerdrCLIExecution.run(
            .init(arguments: ["send", "p1", "resume", "--when-finished", "--in", "15m"]),
            worker: worker)
        #expect(conflict.exitCode == 2 && conflict.stderr.contains("pick one"))
        let cancelled = try await HerdrCLIExecution.run(
            .init(arguments: ["hooks", "rm", hook.id.uuidString, "--json"]), worker: worker)
        #expect(cancelled.exitCode == 0 && cancelled.stderr.isEmpty)
        #expect(await hooks.list().hooks.isEmpty)
        #expect(
            try AgentPayload.decode(
                HerdrHooksSnapshot.self,
                from: Data(contentsOf: root.appendingPathComponent("hooks.json"))
            ).hooks.isEmpty)
        await worker.shutdown()
    }

    private func makeWorker() -> HerdrWorker {
        let defaults = UserDefaults(suiteName: "herdr.cli.fixture." + UUID().uuidString)!
        return HerdrWorker(
            store: HerdrStore(defaults: defaults, machinesProvider: { [] }), defaults: defaults,
            automaticActions: false)
    }
}
