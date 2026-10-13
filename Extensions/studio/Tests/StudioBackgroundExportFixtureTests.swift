import Foundation
import Testing

@MainActor @Suite(.serialized) struct StudioBackgroundExportFixtureTests {
    private enum Failure: Error { case operation, shutdown }

    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var entered = false

        func hold() async {
            entered = true
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    private final class State {
        var finished = false
        var shutdowns = 0
        var callbackReturned = false
        var inputsPresentDuringShutdown = false
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("synthetic.bin"))
        return root
    }

    private func entered(_ gate: Gate) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(gate.entered)
    }

    @Test(arguments: [false, true]) func failureBeforeOpeningControlsJoinsBeforeRemovingInputs(
        directoryCreated: Bool
    ) async throws {
        let root = try directory()
        let gate = Gate()
        let state = State()
        let callback = Task {
            await gate.hold()
            state.callbackReturned = true
        }
        let fixture = StudioBackgroundExportFixture {
            state.shutdowns += 1
            state.inputsPresentDuringShutdown = FileManager.default.fileExists(atPath: root.path)
            await callback.value
        }
        if directoryCreated { fixture.directory = root }
        let operation = Task {
            defer { state.finished = true }
            do {
                try await fixture.run { throw Failure.operation }
                return false
            } catch Failure.operation {
                return true
            }
        }
        do {
            try await entered(gate)
            #expect(!state.finished && !state.callbackReturned)
            #expect(FileManager.default.fileExists(atPath: root.path))
            gate.release()
            #expect(try await operation.value)
            #expect(state.callbackReturned && state.shutdowns == 1)
            #expect(state.inputsPresentDuringShutdown)
            #expect(FileManager.default.fileExists(atPath: root.path) == !directoryCreated)
            if !directoryCreated { try FileManager.default.removeItem(at: root) }
        } catch {
            gate.release()
            _ = await operation.result
            await callback.value
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test func successfulBodyReturnsOnlyAfterOwnedCallbackAndInputRetirement() async throws {
        let root = try directory()
        let gate = Gate()
        let state = State()
        let callback = Task {
            await gate.hold()
            state.callbackReturned = true
        }
        let fixture = StudioBackgroundExportFixture {
            state.shutdowns += 1
            state.inputsPresentDuringShutdown = FileManager.default.fileExists(atPath: root.path)
            await callback.value
        }
        fixture.directory = root
        let operation = Task {
            defer { state.finished = true }
            return try await fixture.run { 17 }
        }
        do {
            try await entered(gate)
            #expect(!state.finished && FileManager.default.fileExists(atPath: root.path))
            gate.release()
            #expect(try await operation.value == 17)
            #expect(state.callbackReturned && state.shutdowns == 1)
            #expect(state.inputsPresentDuringShutdown)
            #expect(!FileManager.default.fileExists(atPath: root.path))
        } catch {
            gate.release()
            _ = await operation.result
            await callback.value
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test func failedShutdownPreservesInputsAndNeverReturnsSuccess() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = StudioBackgroundExportFixture { throw Failure.shutdown }
        fixture.directory = root
        await #expect(throws: Failure.shutdown) {
            try await fixture.run { 17 }
        }
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(fixture.directory == root)
    }

    @Test func releaseBeforeCallbackAdmissionCannotStrandCleanup() async throws {
        let root = try directory()
        let gate = Gate()
        gate.release()
        let callback = Task { await gate.hold() }
        callback.cancel()
        let fixture = StudioBackgroundExportFixture { await callback.value }
        fixture.directory = root
        do {
            #expect(try await fixture.run { 19 } == 19)
            #expect(gate.entered && !FileManager.default.fileExists(atPath: root.path))
        } catch {
            gate.release()
            await callback.value
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
