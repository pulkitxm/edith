import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Testing

@testable import HerdrUI

@MainActor
struct HerdrTerminalConnectionStateTests {
    @Test func supersededCancellationNeitherFailsNorClearsStarting() async {
        let connection = HerdrTerminalConnection()
        var releaseFirst: CheckedContinuation<Void, Never>?
        var releaseSecond: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await connection.run {
                await withCheckedContinuation { releaseFirst = $0 }
                throw CancellationError()
            }
        }
        while releaseFirst == nil { await Task.yield() }
        let second = Task { @MainActor in
            await connection.run {
                await withCheckedContinuation { releaseSecond = $0 }
            }
        }
        while releaseSecond == nil { await Task.yield() }
        releaseFirst?.resume()
        #expect(await first.value == false)
        #expect(connection.error == nil)
        #expect(connection.starting)
        releaseSecond?.resume()
        #expect(await second.value)
        #expect(!connection.starting)
        #expect(connection.error == nil)
    }

    @Test func cancellationWithoutReplacementRetriesThenConnects() async {
        let connection = HerdrTerminalConnection()
        var calls = 0
        let connected = await connection.run {
            calls += 1
            if calls < 3 { throw CancellationError() }
        }
        #expect(connected)
        #expect(calls == 3)
        #expect(connection.error == nil)
    }

    @Test func persistentCancellationSurfacesAFailureInsteadOfABlankPane() async {
        let connection = HerdrTerminalConnection()
        let connected = await connection.run { throw CancellationError() }
        #expect(!connected)
        #expect(connection.error != nil)
        #expect(!connection.starting)
    }

    @Test func realFailureIsReported() async {
        struct Boom: Error {}
        let connection = HerdrTerminalConnection()
        #expect(await connection.run { throw Boom() } == false)
        #expect(connection.error != nil)
    }

    @Test func stoppedRenderingRebindsTheSameEngineSessionOnReconnect() async throws {
        defer { HerdrWorkOwnership.enable() }
        let suite = "herdr.rebind.fixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engineStore = HerdrStore(defaults: defaults, machinesProvider: { [] })
        let worker = HerdrWorker(
            store: engineStore, defaults: defaults, automaticActions: false,
            prepareShell: { _, _ in
                .init(
                    executable: "/bin/sh", arguments: ["-c", "exec cat"],
                    environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"])
            })
        let uiStore = HerdrStore(defaults: defaults, machinesProvider: { [] })
        uiStore.terminalClient = { try await worker.execute($0, payload: $1) }
        let holder = TerminalSessionHolder()
        let target = PaneTarget(
            machineID: Machine.localID, screen: .terminal, argument: "/private/tmp")
        let paneID = UUID()
        try await uiStore.connectShell(holder, paneID: paneID, target: target)
        #expect(holder.isBound)
        let generation = holder.generation
        holder.stopRendering()
        #expect(!holder.isBound)
        #expect(holder.generation > generation)
        try await uiStore.connectShell(holder, paneID: paneID, target: target)
        #expect(holder.isBound)
        await holder.stopAndWait()
        await worker.shutdown()
    }
}
