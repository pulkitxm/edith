import Foundation
import Testing

@testable import MachinesExtension

@Suite @MainActor struct MachineLogEngineTests {
    private func session() -> MachineSession {
        MachineSession(machine: .local, local: true, synthetic: true)
    }

    private func containers(_: MachineSession) -> [DockerContainer] {
        [
            DockerContainer(
                id: "fixture", names: ["fixture"], image: "fixture", command: "", state: .exited,
                status: "Exited")
        ]
    }

    private func process(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        return process
    }

    @Test func preservesOriginalLinesStderrAndFinalExitAcrossBoundedReads() async throws {
        let session = session()
        let engine = MachineLogEngine(
            session: { _ in session }, containers: containers,
            process: { _, _ in
                process(
                    "printf '2026-01-01T00:00:00Z first\\n'; printf 'error\\n' >&2; printf '\\342'; sleep 0.03; printf '\\202\\254\\n'; exit 17"
                )
            })
        let started = try engine.execute(
            MachineLogRequest(operation: .start, machineID: session.id, containerID: "fixture"))
        var sequence: UInt64 = 0
        var lines: [MachineLogChunk] = []
        var code: Int32?
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while code == nil, ContinuousClock.now < deadline {
            let frame = try engine.execute(
                MachineLogRequest(
                    operation: .read, machineID: session.id, handle: started.handle,
                    sequence: sequence))
            sequence = frame.nextSequence
            lines += frame.lines
            code = frame.exitCode
            try await Task.sleep(for: .milliseconds(10))
        }
        await engine.shutdown()
        #expect(code == 17)
        #expect(lines.filter { !$0.isStderr }.map(\.text) == ["2026-01-01T00:00:00Z first", "€"])
        #expect(lines.filter(\.isStderr).map(\.text) == ["error"])
        #expect(sequence == 3)
    }

    @Test func rejectsWrongMachineAndStaleCursorAndStopsExactProcess() async throws {
        let session = session()
        let child = process("printf ready; exec sleep 30")
        let engine = MachineLogEngine(
            session: { _ in session }, containers: containers, process: { _, _ in child })
        let started = try engine.execute(
            MachineLogRequest(operation: .start, machineID: session.id, containerID: "fixture"))
        #expect(throws: MachineUIError.self) {
            try engine.execute(
                MachineLogRequest(operation: .read, machineID: UUID(), handle: started.handle))
        }
        #expect(throws: MachineUIError.self) {
            try engine.execute(
                MachineLogRequest(
                    operation: .read, machineID: session.id, handle: started.handle, sequence: 99))
        }
        _ = try engine.execute(
            MachineLogRequest(operation: .cancel, machineID: session.id, handle: started.handle))
        await engine.shutdown()
        #expect(!child.isRunning)
        #expect(throws: MachineUIError.self) {
            try engine.execute(
                MachineLogRequest(operation: .start, machineID: session.id, containerID: "fixture"))
        }
    }
}
