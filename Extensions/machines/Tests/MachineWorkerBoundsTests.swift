@testable import MachinesExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite struct MachineWorkerBoundsTests {
    @Test func registryRejectsSymlinksAndOversizedDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("machines.json")
        let actual = root.appendingPathComponent("actual.json")
        let machine = Machine(
            name: "Synthetic", host: "synthetic.invalid", createdAt: Date(timeIntervalSince1970: 1))
        let files = MachineRegistry.Files(
            machines: actual, forwards: root.appendingPathComponent("forwards.json"),
            snippets: root.appendingPathComponent("snippets.json"))
        MachineRegistry.add(machine, files)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: actual)
        #expect(MachineRegistry.machines(.init(machines: file)).isEmpty)
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 32, count: 1_048_577).write(to: file)
        #expect(MachineRegistry.machines(.init(machines: file)).isEmpty)
        #expect(SSHConnection.controlPersist == "no")
    }

    @Test func oversizedDownloadTerminatesAndDeletesItsPartialFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let output = try FileHandle(forWritingTo: file)
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 123456789"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        await #expect(throws: SSHConnectionError.self) {
            try await SSHConnection.receiveDownload(
                process: process, reader: pipe.fileHandleForReading,
                output: output, localURL: file, maximumBytes: 4)
        }
        process.waitUntilExit()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!process.isRunning)
    }

    @Test @MainActor func syntheticSessionHasNoConnectionsCollectorsOrAutomaticWork() async {
        let session = MachineSession(
            machine: Machine(name: "Synthetic", host: "synthetic.invalid"), synthetic: true)
        session.start()
        session.setForegroundObservation(UUID(), active: true)
        session.beginInternetSpeedObservation()
        #expect(session.state.isConnected)
        #expect(!session.isCollecting)
        #expect(session.connectionRef == nil)
        #expect(session.sample?.cpu.total == 32)
        let result = await session.runCommand("printf synthetic")
        if case .success = result { Issue.record("synthetic fixture executed a command") }
        await session.shutdown()
        #expect(session.state == .disconnected)
        #expect(!session.isCollecting)
    }

    @Test func stoppingAnSSHProcessWaitsForExitEvenWhenTheOwnerIsCancelled() async throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(60)",
        ]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        #expect(
            String(decoding: output.fileHandleForReading.readData(ofLength: 6), as: UTF8.self)
                == "ready\n")
        let stop = Task { await SSHConnection.stopProcess(process) }
        stop.cancel()
        await stop.value
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
    }

    @Test func remoteUsageOperationHasOnlyFixedNativeCommandsAndPaths() throws {
        let forced = try MachineRemoteUsageOperation.command(platform: .darwin, force: true)
        #expect(forced.contains("bash -lc"))
        let script = String(decoding: try MachineRemoteUsageOperation.input(), as: UTF8.self)
        #expect(script.contains("sqlite3"))
        #expect(script.contains("67108864"))
        #expect(!forced.contains("ed usage"))
        #expect(!forced.contains("curl"))
        #expect(!forced.contains("bun"))
        #expect(!forced.contains("npm"))
        #expect(
            try MachineRemoteUsageOperation.command(platform: .windows, force: true).contains(
                "-EncodedCommand"))
    }
}
