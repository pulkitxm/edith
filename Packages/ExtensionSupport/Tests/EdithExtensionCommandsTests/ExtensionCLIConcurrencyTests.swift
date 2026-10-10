import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

extension ExtensionCLIExecutionTests {
    @Test func simultaneousRequestsKeepDifferentContextAndChildTaskOutputAfterOneCancellation()
        async throws
    {
        let gate = ExecutionGate()
        try await ConcurrentFixture.$gate.withValue(gate) {
            let first = Task {
                try await ExtensionCLIExecution.run(
                    ConcurrentCommand.self,
                    request: ExtensionCLIRequest(
                        arguments: ["first"], standardInput: Data("input-first".utf8),
                        workingDirectory: "/synthetic/first", interactive: true))
            }
            let second = Task {
                try await ExtensionCLIExecution.run(
                    ConcurrentCommand.self,
                    request: ExtensionCLIRequest(
                        arguments: ["second"], standardInput: Data("input-second".utf8),
                        workingDirectory: "/synthetic/second", interactive: false))
            }
            defer { first.cancel(); second.cancel() }
            try await concurrentUntil { gate.arrived.count == 2 }
            first.cancel()
            await #expect(throws: CancellationError.self) { try await first.value }
            #expect(gate.cancelled == ["first"])
            #expect(!gate.departed.contains("second"))
            gate.release("second")
            let reply = try await second.value
            #expect(
                reply.stdout
                    == "second:/synthetic/second\nchild:/synthetic/second/child\nfinished:second\n")
            #expect(reply.stderr == "input-second:false\n")
            #expect(reply.exitCode == 0)
        }
        #expect(ExtensionCLIContext.request == nil)
        #expect(ExtensionCLIContext.outputSink == nil)
        #expect(ExtensionCLIContext.rawOutputSink == nil)
    }

    @Test func refreshAndFollowStreamTheSameOwnedEventsInTheirOwnContexts() async throws {
        let refresh = SharedRefresh()
        try await ConcurrentFixture.$refresh.withValue(refresh) {
            let streams = try ExtensionCLIStreams(owner: "refresh-fixture")
            defer { refresh.finish(); streams.stop() }
            @MainActor func start(_ label: String, follow: Bool) throws -> ExtensionCLIStreamHandle
            {
                try streams.start(
                    RefreshCommand.self,
                    request: .init(
                        owner: streams.owner, session: UUID(),
                        request: ExtensionCLIRequest(
                            arguments: [label] + (follow ? ["--follow"] : []),
                            standardInput: Data([follow ? 2 : 1, 0, 0xFF]),
                            workingDirectory: "/synthetic/\(label)", interactive: !follow)))
            }
            let creator = try start("creator", follow: false)
            try await concurrentUntil { refresh.listeners.count == 1 }
            let follower = try start("follower", follow: true)
            try await concurrentUntil { refresh.listeners.count == 2 }
            #expect(refresh.starts == 1)
            refresh.emit("collecting")
            try await concurrentUntil {
                refresh.received["creator"] == 1 && refresh.received["follower"] == 1
            }
            let created = try streams.read(.init(handle: creator, sequence: 0))
            let followed = try streams.read(.init(handle: follower, sequence: 0))
            #expect(created.state == .running && followed.state == .running)
            #expect(
                joined(created.chunks, channel: .stdout) == Data(
                    "/synthetic/creator|true|collecting\n".utf8) + Data([1, 0, 0xFF]))
            #expect(
                joined(followed.chunks, channel: .stdout) == Data(
                    "/synthetic/follower|false|collecting\n".utf8) + Data([2, 0, 0xFF]))
            #expect(joined(created.chunks, channel: .stderr) == Data("creator:collecting\n".utf8))
            #expect(joined(followed.chunks, channel: .stderr) == Data("follower:collecting\n".utf8))
            try streams.cancel(follower)
            let cancelled = try await concurrentTerminal(streams, follower, followed.nextSequence)
            #expect(cancelled.state == .cancelled && cancelled.exitCode == nil)
            #expect(refresh.listeners.count == 1 && !refresh.finished)
            refresh.emit("saving")
            try await concurrentUntil { refresh.received["creator"] == 2 }
            #expect(refresh.received["follower"] == 1)
            refresh.finish()
            let completed = try await concurrentTerminal(streams, creator, created.nextSequence)
            #expect(completed.state == .completed && completed.exitCode == 0)
            #expect(
                joined(completed.chunks, channel: .stdout) == Data(
                    "/synthetic/creator|true|saving\n".utf8) + Data([1, 0, 0xFF]))
            #expect(joined(completed.chunks, channel: .stderr) == Data("creator:saving\n".utf8))
            #expect(refresh.listeners.isEmpty)
            await streams.stopAndWait()
        }
        #expect(ExtensionCLIContext.request == nil && ExtensionCLIContext.rawOutputSink == nil)
    }

    @Test func eightLiveExecutionsStayBoundedAndStopWaitsForAnEndedIgnoringTask() async throws {
        let gate = ExecutionGate()
        try await ConcurrentFixture.$gate.withValue(gate) {
            let streams = try ExtensionCLIStreams(owner: "capacity-fixture")
            defer { gate.release("0"); streams.stop() }
            var handles: [ExtensionCLIStreamHandle] = []
            for index in 0..<8 {
                handles.append(
                    try streams.start(
                        ConcurrentCommand.self,
                        request: .init(
                            owner: streams.owner, session: UUID(),
                            request: ExtensionCLIRequest(
                                arguments: [String(index)] + (index == 0 ? ["--resist"] : [])))))
            }
            try await concurrentUntil { gate.arrived.count == 8 && gate.resisting != nil }
            #expect(ExtensionCLIExecution.maximumConcurrentExecutions == 8)
            #expect(throws: ExtensionPeerError.self) {
                try streams.start(
                    ConcurrentCommand.self,
                    request: .init(
                        owner: streams.owner, session: UUID(), request: .init(arguments: ["ninth"]))
                )
            }
            await #expect(throws: ExtensionPeerError.self) {
                try await ExtensionCLIExecution.run(ConcurrentCommand.self, arguments: ["ninth"])
            }
            #expect(!gate.arrived.contains("ninth"))
            try streams.end(handles[0])
            #expect(throws: ExtensionPeerError.self) {
                try streams.start(
                    ConcurrentCommand.self,
                    request: .init(
                        owner: streams.owner, session: UUID(), request: .init(arguments: ["ninth"]))
                )
            }
            var stopped = false
            let stop = Task {
                await streams.stopAndWait(); stopped = true
            }
            try await concurrentUntil { gate.departed.count == 7 }
            #expect(!stopped)
            gate.release("0")
            await stop.value
            #expect(stopped && gate.departed.count == 8)
            #expect(gate.cancelled.count == 8)
            for handle in handles {
                #expect(throws: ExtensionPeerError.self) {
                    try streams.read(.init(handle: handle, sequence: 0))
                }
            }
            let after = try await ExtensionCLIExecution.run(FreshCommand.self, arguments: [])
            #expect(after.stdout == "fresh\n")
        }
    }

    private func concurrentUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw CLIFailure("Concurrent fixture timed out")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func joined(
        _ chunks: [ExtensionCLIStreamChunk], channel: ExtensionCLIStreamChunk.Channel
    ) -> Data {
        chunks.filter { $0.channel == channel }.reduce(into: Data()) { $0.append($1.data) }
    }

    private func concurrentTerminal(
        _ streams: ExtensionCLIStreams, _ handle: ExtensionCLIStreamHandle, _ sequence: UInt64
    ) async throws -> ExtensionCLIStreamFrame {
        let deadline = ContinuousClock.now + .seconds(5)
        var cursor = sequence
        var chunks: [ExtensionCLIStreamChunk] = []
        while ContinuousClock.now < deadline {
            let frame = try streams.read(.init(handle: handle, sequence: cursor))
            try frame.validate()
            chunks += frame.chunks
            guard chunks.count <= 64,
                chunks.reduce(0, { $0 + $1.data.count })
                    <= ExtensionCLIStreamFrame.maximumFrameBytes
            else { throw CLIFailure("Concurrent fixture exceeded expected bounded output") }
            cursor = frame.nextSequence
            if frame.state != .running {
                return ExtensionCLIStreamFrame(
                    handle: handle, sequence: sequence, nextSequence: cursor, chunks: chunks,
                    state: frame.state, exitCode: frame.exitCode)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CLIFailure("Concurrent stream did not finish")
    }
}

private enum ConcurrentFixture {
    @TaskLocal static var gate: ExecutionGate?
    @TaskLocal static var refresh: SharedRefresh?
}

@MainActor
private final class ExecutionGate {
    var arrived: Set<String> = []
    var departed: Set<String> = []
    var cancelled: Set<String> = []
    var released: Set<String> = []
    var resisting: CheckedContinuation<Void, Never>?

    func wait(_ name: String, resist: Bool) async throws {
        arrived.insert(name)
        defer { departed.insert(name) }
        if resist {
            await withCheckedContinuation { resisting = $0 }
            if Task.isCancelled { cancelled.insert(name) }
            try Task.checkCancellation()
        } else {
            do {
                while !released.contains(name) { try await Task.sleep(for: .milliseconds(5)) }
            } catch {
                if Task.isCancelled { cancelled.insert(name) }
                throw error
            }
        }
    }

    func release(_ name: String) {
        released.insert(name)
        if name == "0" { resisting?.resume(); resisting = nil }
    }
}

private struct ConcurrentCommand: AsyncParsableCommand {
    @Argument var name: String
    @Flag var resist = false
    @MainActor mutating func run() async throws {
        let gate = try #require(ConcurrentFixture.gate)
        let request = try #require(ExtensionCLIContext.request)
        CLIOut.out("\(name):\(request.workingDirectory)")
        CLIOut.note(
            "\(String(data: request.standardInput, encoding: .utf8) ?? ""):\(request.interactive)")
        try await gate.wait(name, resist: resist)
        let child = Task {
            CLIOut.out("child:\(try ExtensionCLIContext.resolvePath("child").path)")
        }
        try await child.value
        CLIOut.out("finished:\(name)")
    }
}

@MainActor
private final class SharedRefresh {
    var starts = 0
    var finished = false
    var received: [String: Int] = [:]
    var listeners: [String: AsyncStream<String>.Continuation] = [:]

    func attach(_ name: String, follow: Bool) throws -> AsyncStream<String> {
        guard listeners.count < 8, listeners[name] == nil, !finished,
            follow ? starts == 1 : starts == 0
        else { throw CLIFailure.unavailable("No matching owned refresh") }
        if !follow { starts += 1 }
        return AsyncStream(bufferingPolicy: .bufferingNewest(4)) { listeners[name] = $0 }
    }

    func emit(_ event: String) { for listener in listeners.values { listener.yield(event) } }
    func finish() { finished = true; for listener in listeners.values { listener.finish() } }
}

private struct RefreshCommand: AsyncParsableCommand {
    @Argument var name: String
    @Flag var follow = false
    @MainActor mutating func run() async throws {
        let refresh = try #require(ConcurrentFixture.refresh)
        let request = try #require(ExtensionCLIContext.request)
        let events = try refresh.attach(name, follow: follow)
        defer { refresh.listeners.removeValue(forKey: name) }
        for await event in events {
            try Task.checkCancellation()
            CLIOut.raw("\(request.workingDirectory)|\(request.interactive)|\(event)\n")
            try CLIOut.raw(request.standardInput)
            CLIOut.note("\(name):\(event)")
            refresh.received[name, default: 0] += 1
        }
        try Task.checkCancellation()
    }
}

private struct FreshCommand: AsyncParsableCommand {
    mutating func run() async throws { CLIOut.out("fresh") }
}
