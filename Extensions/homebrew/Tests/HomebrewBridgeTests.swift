import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import HomebrewExtension

@Suite(.serialized) @MainActor struct HomebrewBridgeTests {
    @Test func originalCLIListSearchPreviewAndHelpUseOwnedClient() async throws {
        let recorder = Requests()
        let owner = makeOwner(recorder)
        let list = try await HomebrewCLIExecution.run(
            .init(arguments: ["list", "--json"]), owner: owner)
        #expect(list.exitCode == 0 && list.stderr.isEmpty)
        #expect(
            list.stdout.contains("synthetic-formula") && list.stdout.contains("installedVersions"))
        let search = try await HomebrewCLIExecution.run(
            .init(arguments: ["search", "synthetic", "--kind", "formula", "--json"]), owner: owner)
        #expect(search.exitCode == 0 && search.stdout.contains("synthetic-formula"))
        let before = recorder.arguments.count
        let preview = try await HomebrewCLIExecution.run(
            .init(arguments: ["uninstall", "synthetic-formula", "--json"]), owner: owner)
        #expect(preview.exitCode == 0 && preview.stderr.isEmpty)
        #expect(preview.stdout.contains("\"applied\": false") && recorder.arguments.count == before)
        for command in ["status", "ls", "search", "install", "upgrade", "uninstall", "cancel"] {
            let help = try await HomebrewCLIExecution.run(
                .init(arguments: [command, "--help"]), owner: owner)
            #expect(help.exitCode == 0 && help.stderr.isEmpty && help.stdout.contains("USAGE:"))
        }
        let invalid = try await HomebrewCLIExecution.run(
            .init(arguments: ["install", "--kind", "wrong", "x"]), owner: owner)
        #expect(invalid.exitCode == 2 && invalid.stdout.isEmpty && !invalid.stderr.isEmpty)
    }

    @Test func remoteOriginalModelLoadsOwnedInventoryAndPersistsOnlyInEngine() async throws {
        let recorder = Requests()
        let owner = makeOwner(recorder)
        let bridge = Bridge(owner: owner)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let model = HomebrewPageModel(engineClient: client)
        model.activate(kind: .formula)
        try await wait { model.loaded && !model.isBusy }
        #expect(model.status?.available == true)
        #expect(model.packages.map(\.name) == ["synthetic-formula"])
        #expect(bridge.operations == ["homebrew.cache", "homebrew.status", "homebrew.list"])
        #expect((await ownerCache(owner))?.packages[.formula]?.count == 1)
        model.search("synthetic", kind: .formula)
        try await wait { !model.isBusy }
        #expect(bridge.operations.last == "homebrew.search")
        client.invalidate()
        model.search("later", kind: .formula)
        try await wait { !model.isBusy }
        #expect(model.errorMessage != nil)
    }

    @Test func cancelAndDisableDrainOnlyOwnedMutationAndRejectLateReads() async throws {
        let recorder = Requests()
        recorder.hold = true
        let owner = makeOwner(recorder)
        let task = Task {
            try await owner.mutate(.install, kind: .formula, name: "synthetic-formula")
        }
        try await wait { recorder.arguments.contains(["install", "synthetic-formula"]) }
        #expect(owner.cancel())
        await #expect(throws: CancellationError.self) { try await task.value }
        await owner.shutdownAndWait()
        await #expect(throws: ExtensionPeerError.self) {
            try await owner.execute("homebrew.status", payload: Data("{}".utf8))
        }
        let live = makeOwner(Requests())
        await #expect(throws: ExtensionPeerError.self) {
            try await live.execute(
                "homebrew.install",
                payload: Data("{\"kind\":\"formula\",\"name\":\"x\",\"shell\":\"bad\"}".utf8))
        }
    }

    private func makeOwner(_ recorder: Requests) -> HomebrewEngineCommands {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("listing.json")
        recorder.directory = url.deletingLastPathComponent()
        return HomebrewEngineCommands(
            client: HomebrewClient(executableURL: URL(fileURLWithPath: "/synthetic/brew")) {
                request, _ in
                recorder.record(request.arguments)
                if request.arguments.first == "install", recorder.hold {
                    try await Task.sleep(for: .seconds(30))
                }
                let output: String
                switch request.arguments.first {
                case "--version": output = "Homebrew synthetic\n"
                case "search": output = "synthetic-formula\n"
                case "outdated": output = "{\"formulae\":[],\"casks\":[]}"
                default:
                    output =
                        "{\"formulae\":[{\"name\":\"synthetic-formula\",\"installed\":[{\"version\":\"1\"}],\"versions\":{\"stable\":\"1\"}}],\"casks\":[]}"
                }
                return CLICommandResult(terminationStatus: 0, output: output)
            }, store: HomebrewListingStore(fileURL: url))
    }

    private func ownerCache(_ owner: HomebrewEngineCommands) async -> HomebrewListingSnapshot? {
        guard let data = try? await owner.execute("homebrew.cache", payload: Data("{}".utf8)) else {
            return nil
        }
        return try? JSONDecoder().decode(HomebrewListingSnapshot.self, from: data)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ExtensionEngineError.timedOut }
            await Task.yield()
        }
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[String]] = []
        var hold = false
        var directory: URL?
        var arguments: [[String]] { lock.withLock { values } }
        func record(_ arguments: [String]) { lock.withLock { values.append(arguments) } }
        deinit { if let directory { try? FileManager.default.removeItem(at: directory) } }
    }

    private final class Bridge: NSObject {
        let owner: HomebrewEngineCommands
        var operations: [String] = []
        var tasks: [UUID: Task<Void, Never>] = [:]
        init(owner: HomebrewEngineCommands) { self.owner = owner }
        @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion(Data()); return }
            operations.append(request.operation)
            tasks[request.token] = Task {
                let payload = try? await owner.execute(request.operation, payload: request.payload)
                let reply = ExtensionEngineReply(
                    token: request.token, ok: payload != nil, payload: payload ?? Data("{}".utf8))
                completion((try? ExtensionEngineWire.encode(reply)) ?? Data())
                tasks[request.token] = nil
            }
        }
        @objc func cancel(_ token: String) {
            guard let token = UUID(uuidString: token) else { return }
            tasks.removeValue(forKey: token)?.cancel()
        }
    }
}
