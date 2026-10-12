import EdithExtensionSupport
import Foundation
import Testing

@MainActor @Suite struct HostCommandFixtureDrainTests {
    @Test(arguments: [false, true], [false, true])
    func completionJoinsHeldCommandAndOwnedTask(stop: Bool, commandReturnsFirst: Bool) async throws
    {
        let commands = ExtensionCommandRegistry()
        let command = CommandFixtureGate()
        let background = CommandFixtureGate()
        let owner = Task { await background.hold() }
        var replies = 0
        commands.invoke(
            ["token": UUID().uuidString, "command": "fixture.held", "payload": Data()],
            completion: { bytes, message in
                #expect(bytes == nil && message != nil)
                replies += 1
            },
            execute: { _, _ in
                await command.hold()
                return Data()
            })
        defer {
            command.release()
            background.release()
            owner.cancel()
            commands.shutdown()
        }
        do {
            try await wait { command.entered && background.entered }
            let runtime = CommandFixtureRuntime(task: owner, commands: commands)
            var completions = 0
            let completed = {
                #expect(command.returned && background.returned)
                #expect(command.cancelled && background.cancelled)
                completions += 1
            }
            if stop {
                runtime.prepareToStop(completion: completed)
            } else {
                runtime.suspendCommands(completion: completed)
            }
            #expect(replies == 1)
            #expect(owner.isCancelled)
            #expect(completions == 0)
            let first = commandReturnsFirst ? command : background
            let second = commandReturnsFirst ? background : command
            first.release()
            try await wait { first.returned }
            #expect(!second.returned && completions == 0)
            second.release()
            try await wait { completions == (stop ? 2 : 1) }
            await owner.value
            #expect(replies == 1)
            var rejected = false
            commands.invoke(
                ["token": UUID().uuidString, "command": "fixture.late", "payload": Data()],
                completion: { bytes, message in rejected = bytes == nil && message != nil },
                execute: { _, _ in
                    Issue.record("A retired fixture accepted new work.")
                    return Data()
                })
            #expect(rejected)
        } catch {
            command.release()
            background.release()
            owner.cancel()
            commands.shutdown()
            await owner.value
            await commands.shutdownAndWait()
            throw error
        }
        commands.shutdown()
        await commands.shutdownAndWait()
        await owner.value
    }

    @Test func releasedGateReturnsWhenCancelledOwnerEntersLater() async throws {
        let gate = CommandFixtureGate()
        gate.release()
        let owner = Task { await gate.hold() }
        owner.cancel()
        do {
            try await wait { gate.returned }
            await owner.value
            #expect(gate.entered && gate.cancelled)
        } catch {
            gate.release()
            owner.cancel()
            await owner.value
            throw error
        }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw DrainTestError.timedOut }
            await Task.yield()
        }
    }
}

private enum DrainTestError: Error {
    case timedOut
}

@MainActor private final class CommandFixtureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    private(set) var returned = false
    private(set) var cancelled = false

    func hold() async {
        entered = true
        if !released {
            await withCheckedContinuation {
                continuation = $0
            }
        }
        cancelled = Task.isCancelled
        returned = true
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
