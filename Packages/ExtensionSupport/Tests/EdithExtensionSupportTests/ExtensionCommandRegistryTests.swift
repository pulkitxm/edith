import Foundation
import Testing
@testable import EdithExtensionSupport

private actor CommandCleanupGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func pause() async {
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}

@MainActor @Suite struct ExtensionCommandRegistryTests {
    @Test(arguments: [false, true])
    func shutdownAwaitsCancelledCommandCleanup(cancelFirst: Bool) async throws {
        let registry = ExtensionCommandRegistry()
        let gate = CommandCleanupGate()
        let token = UUID().uuidString
        var entered = false
        var completed = 0
        registry.invoke(
            ["token": token, "command": "fixture", "payload": Data()] as NSDictionary,
            completion: { data, error in
                #expect(data == nil)
                #expect(error != nil)
                completed += 1
            }
        ) { _, _ in
            entered = true
            do { try await Task.sleep(for: .seconds(30)) } catch { await gate.pause(); throw error }
            return Data()
        }
        for _ in 0..<100 where !entered { try await Task.sleep(for: .milliseconds(2)) }
        #expect(entered)
        if cancelFirst { registry.cancel(token) }
        var stopped = false
        let shutdown = Task {
            await registry.shutdownAndWait(); stopped = true
        }
        for _ in 0..<100 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await gate.entered)
        #expect(!stopped)
        #expect(completed == 1)
        await gate.release()
        await shutdown.value
        #expect(stopped)
        #expect(completed == 1)
        var ranAfterStop = false
        registry.invoke(
            ["token": UUID().uuidString, "command": "fixture", "payload": Data()] as NSDictionary,
            completion: { data, error in
                #expect(data == nil)
                #expect(error != nil)
            }
        ) { _, _ in
            ranAfterStop = true; return Data()
        }
        #expect(!ranAfterStop)
    }
    @Test func cancelledCommandsRetainAdmissionUntilTheirCleanupFinishes() async throws {
        let registry = ExtensionCommandRegistry()
        let gates = (0..<8).map { _ in CommandCleanupGate() }
        let tokens = (0..<8).map { _ in UUID().uuidString }
        for (token, gate) in zip(tokens, gates) {
            registry.invoke(
                ["token": token, "command": "fixture", "payload": Data()] as NSDictionary,
                completion: { _, _ in }
            ) { _, _ in
                await gate.pause()
                return Data()
            }
        }
        for gate in gates {
            for _ in 0..<100 {
                if await gate.entered { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(await gate.entered)
        }
        for token in tokens { registry.cancel(token) }
        var rejected = 0
        var unexpected = false
        for token in [tokens[0], UUID().uuidString] {
            registry.invoke(
                ["token": token, "command": "fixture", "payload": Data()] as NSDictionary,
                completion: { data, error in
                    #expect(data == nil)
                    #expect(error != nil)
                    rejected += 1
                }
            ) { _, _ in
                unexpected = true
                return Data()
            }
        }
        #expect(rejected == 2)
        #expect(!unexpected)
        for gate in gates { await gate.release() }
        await registry.shutdownAndWait()
        #expect(!unexpected)
    }

}
