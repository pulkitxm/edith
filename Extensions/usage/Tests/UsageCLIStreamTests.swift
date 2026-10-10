import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageCLIStreamTests {
    private func start(
        _ arguments: [String], streams: ExtensionCLIStreams, controller: UsageWorkerController,
        input: Data = Data(), workingDirectory: String = "/", interactive: Bool = false
    ) throws -> ExtensionCLIStreamHandle {
        let request = ExtensionCLIStreamStart(
            owner: "usage", session: UUID(),
            request: try ExtensionCLIRequest(
                arguments: arguments, standardInput: input,
                workingDirectory: workingDirectory, interactive: interactive), deadline: 10)
        return try UsageCLIEnvironment.$resources.withValue(
            UsageCLIResources(controller: controller)
        ) {
            let reply = try streams.invoke(
                UsageCommand.self, operation: "usage.cli.start", prefix: "usage.cli",
                payload: JSONEncoder().encode(request))
            return try JSONDecoder().decode(ExtensionCLIStreamHandle.self, from: reply)
        }
    }

    private func drain(
        _ handle: ExtensionCLIStreamHandle, streams: ExtensionCLIStreams
    ) async throws -> ([ExtensionCLIStreamChunk], ExtensionCLIStreamFrame) {
        var chunks: [ExtensionCLIStreamChunk] = []
        var sequence: UInt64 = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let data = try streams.invoke(
                UsageCommand.self, operation: "usage.cli.read", prefix: "usage.cli",
                payload: JSONEncoder().encode(
                    ExtensionCLIStreamRead(handle: handle, sequence: sequence)))
            let frame = try JSONDecoder().decode(ExtensionCLIStreamFrame.self, from: data)
            try frame.validate()
            #expect(frame.sequence == sequence)
            chunks += frame.chunks
            sequence = frame.nextSequence
            if frame.state != .running { return (chunks, frame) }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CLIFailure.unavailable("the owned test stream did not finish")
    }

    private func invoke(
        _ runtime: ExtensionRuntime, command: String, payload: Data
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            runtime.invoke(
                ["token": UUID().uuidString, "command": command, "payload": payload]
                    as NSDictionary
            ) { data, error in
                if let data {
                    continuation.resume(returning: data as Data)
                } else {
                    continuation.resume(
                        throwing: CLIFailure.unavailable(error.map(String.init) ?? "no reply"))
                }
            }
        }
    }

    @Test func engineRegistryRoutesStreamsAndDisableRejectsFurtherRequests() async throws {
        let fixture = try UsageIssuedFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: Repo.dataDir, withIntermediateDirectories: true)
        try Data(CLIUsageTests.document.utf8).write(to: Repo.usageJSON)
        defer { try? FileManager.default.removeItem(at: Repo.usageJSON) }
        let runtime = ExtensionRuntime(admitFixture: fixture.admit)
        let started = runtime.execute(fixture.input(operation: "start"))
        try #require((started as? NSDictionary)?["ok"] as? Bool == true)
        let catalog = try await invoke(runtime, command: "usage.cli.catalog", payload: Data())
        let metadata = try #require(
            try JSONSerialization.jsonObject(with: catalog) as? [String: Any])
        #expect(metadata["owner"] as? String == "usage")
        let get = try ExtensionCLIRequest(arguments: ["get", "dashRange", "--json"])
        let config = try await invoke(
            runtime, command: "usage.config.cli", payload: JSONEncoder().encode(get))
        let value = try JSONDecoder().decode(ExtensionCLIReply.self, from: config)
        #expect(value.exitCode == 0 && value.stdout.contains("dashRange"))
        let request = ExtensionCLIStreamStart(
            owner: "usage", session: UUID(),
            request: try ExtensionCLIRequest(arguments: ["summary", "--json"]), deadline: 10)
        let data = try await invoke(
            runtime, command: "usage.cli.start", payload: JSONEncoder().encode(request))
        let handle = try JSONDecoder().decode(ExtensionCLIStreamHandle.self, from: data)
        let error: NSError? = await withCheckedContinuation { continuation in
            runtime.prepareDisable { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        await #expect(throws: (any Error).self) {
            try await invoke(
                runtime, command: "usage.cli.read",
                payload: JSONEncoder().encode(ExtensionCLIStreamRead(handle: handle, sequence: 0)))
        }
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
    }

    @Test func reportsPreserveOutputChannelsExitCodeAndRejectStaleHandles() async throws {
        try FileManager.default.createDirectory(at: Repo.dataDir, withIntermediateDirectories: true)
        try Data(CLIUsageTests.document.utf8).write(to: Repo.usageJSON)
        defer { try? FileManager.default.removeItem(at: Repo.usageJSON) }
        let controller = UsageWorkerController(
            dataDirectory: Repo.dataDir, collect: { _, _ in Data() })
        let streams = try ExtensionCLIStreams(owner: "usage")
        let summary = try start(
            ["summary", "--source", "codex", "--json"], streams: streams, controller: controller)
        let (chunks, frame) = try await drain(summary, streams: streams)
        #expect(frame.state == .completed && frame.exitCode == 0)
        #expect(chunks.allSatisfy { $0.channel == .stdout })
        let data = chunks.reduce(into: Data()) { $0.append($1.data) }
        let result = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((result["totals"] as? [String: Any])?["tokens"] as? Int == 4)
        #expect(throws: (any Error).self) {
            try streams.read(ExtensionCLIStreamRead(handle: summary, sequence: 0))
        }
        try streams.end(summary)
        #expect(throws: (any Error).self) {
            try streams.read(ExtensionCLIStreamRead(handle: summary, sequence: frame.nextSequence))
        }
        let invalid = try start(
            ["summary", "--source", "missing", "--json"], streams: streams, controller: controller)
        let (errors, failed) = try await drain(invalid, streams: streams)
        #expect(failed.state == .completed && failed.exitCode == 3)
        #expect(errors.allSatisfy { $0.channel == .stderr })
        #expect(
            String(decoding: errors.reduce(into: Data()) { $0.append($1.data) }, as: UTF8.self)
                .contains("no usage source named missing"))
        try streams.end(invalid)
        await streams.stopAndWait()
        await controller.shutdown()
    }

    @Test func statuslineStreamRetainsCallerInputAndInteractiveContext() async throws {
        let controller = UsageWorkerController(
            dataDirectory: Repo.dataDir, collect: { _, _ in Data() })
        let streams = try ExtensionCLIStreams(owner: "usage")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.resolvingSymlinksInPath().path
        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":29}}}"#.utf8)
        let handle = try start(
            ["statusline", "record", "--then", "/bin/pwd; /bin/cat"], streams: streams,
            controller: controller, input: input, workingDirectory: directory)
        let (chunks, frame) = try await drain(handle, streams: streams)
        #expect(frame.exitCode == 0 && chunks.allSatisfy { $0.channel == .stdout })
        let output = chunks.reduce(into: Data()) { $0.append($1.data) }
        let separator = try #require(output.firstIndex(of: 10))
        let actualDirectory = String(decoding: output[..<separator], as: UTF8.self)
        #expect(
            URL(fileURLWithPath: actualDirectory).resolvingSymlinksInPath()
                == root.resolvingSymlinksInPath())
        #expect(output.suffix(from: output.index(after: separator)) == input)
        try streams.end(handle)
        let interactive = try ExtensionCLIRequest(arguments: [], interactive: true)
        ExtensionCLIContext.$request.withValue(interactive) {
            #expect(CLIStyle.isInteractive)
            #expect(CLIStyle.green("ready").contains("\u{1B}[32m"))
        }
        let redirected = try ExtensionCLIRequest(arguments: [], interactive: false)
        ExtensionCLIContext.$request.withValue(redirected) {
            #expect(!CLIStyle.isInteractive)
            #expect(CLIStyle.green("ready") == "ready")
        }
        await streams.stopAndWait()
        await controller.shutdown()
    }

    @Test func wrappedStatuslineStreamPreservesRawBytesAndExactCallerInput() async throws {
        let controller = UsageWorkerController(
            dataDirectory: Repo.dataDir,
            collect: { _, _ in
                Issue.record("Statusline must not start a collector")
                throw ExtensionPeerError.unavailable
            })
        let streams = try ExtensionCLIStreams(owner: "usage")
        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":31}}}"#.utf8)
        let command = #"printf '\000\377\303\050'; /bin/cat; printf 'discarded diagnostic' >&2"#
        let handle = try start(
            ["statusline", "record", "--then", command], streams: streams,
            controller: controller, input: input)
        let (chunks, frame) = try await drain(handle, streams: streams)
        #expect(frame.state == .completed && frame.exitCode == 0)
        #expect(chunks.allSatisfy { $0.channel == .stdout })
        let output = chunks.reduce(into: Data()) { $0.append($1.data) }
        #expect(output == Data([0, 255, 195, 40]) + input)
        try streams.end(handle)
        await streams.stopAndWait()
        await controller.shutdown()
    }

    @Test func cancellingAndStoppingStreamsCancelOnlyTheirOwnedRefresh() async throws {
        let cancelled = UsageCLIStreamCancellation()
        let controller = UsageWorkerController(
            dataDirectory: Repo.dataDir,
            collect: { _, _ in
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    await cancelled.record()
                    throw error
                }
                return Data()
            })
        let streams = try ExtensionCLIStreams(owner: "usage")
        let handle = try start(
            ["refresh", "--no-machines", "--json"], streams: streams, controller: controller)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !controller.refreshing && ContinuousClock.now < deadline { await Task.yield() }
        try #require(controller.refreshing)
        try streams.cancel(handle)
        let (_, frame) = try await drain(handle, streams: streams)
        #expect(frame.state == .cancelled && frame.exitCode == nil)
        await streams.stopAndWait()
        #expect(await cancelled.value)
        #expect(!controller.refreshing)
        #expect(throws: (any Error).self) {
            try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: frame.nextSequence))
        }
        let background = UsageWorkerController(
            dataDirectory: Repo.dataDir,
            collect: { _, _ in
                try await Task.sleep(for: .seconds(60)); return Data()
            })
        try background.requestRefresh(policy: .skip)
        let follower = try ExtensionCLIStreams(owner: "usage")
        let following = try start(
            ["refresh", "--follow", "--json"], streams: follower, controller: background)
        try await Task.sleep(for: .milliseconds(50))
        try follower.cancel(following)
        await follower.stopAndWait()
        #expect(background.refreshing)
        await background.cancelRefresh()
        await background.shutdown()
        await controller.shutdown()
    }
}

private actor UsageCLIStreamCancellation {
    private(set) var value = false

    func record() { value = true }
}
