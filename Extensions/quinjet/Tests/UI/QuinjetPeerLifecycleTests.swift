import Darwin
import EdithExtensionSupport
import Foundation
import Testing
@testable import QuinjetUI

@MainActor @Suite(.serialized) struct QuinjetPeerLifecycleTests {
    @Test func savedConnectionRecipeRetainsPortKeyAndMasterAndClearsOnDisconnect() async throws {
        let id = UUID()
        let target = "mock@synthetic.invalid"
        try await MachineRegistry.refresh { command, data, _ in
            #expect(command == "machines.companion.hosts" && data == Data("{}".utf8))
            return try JSONSerialization.data(withJSONObject: [
                "machines": [["id": id.uuidString, "name": "Synthetic", "sshTarget": target]]
            ])
        }
        defer { MachineRegistry.shutdown() }
        let machine = try #require(MachineRegistry.machines().first)
        let arguments =
            SSHConnection.masterOnlyOptions + [
                "-p", "2222", "-i", "/tmp/mock-key", "-S", "/tmp/mock-master", "--", target,
            ]
        let connection = SSHConnection(machine: machine) { command, data, _ in
            #expect(command == "machines.connection.prepare")
            let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
            #expect(object == ["machineID": id.uuidString])
            return try JSONSerialization.data(withJSONObject: [
                "machineID": id.uuidString, "name": "Synthetic", "sshTarget": target,
                "sshArguments": arguments, "controlPath": "/tmp/mock-master", "platform": "linux",
            ])
        }
        #expect(throws: ExtensionPeerError.self) { try connection.terminalArguments() }
        try await connection.connect()
        #expect(
            try connection.execArguments(command: "readonly") == ["-T"] + arguments + ["readonly"])
        #expect(try connection.terminalArguments() == ["-tt"] + arguments)
        #expect(connection.controlSocketPath == "/tmp/mock-master")
        #expect(await connection.remotePlatform == .linux)
        await connection.disconnect()
        #expect(throws: ExtensionPeerError.self) { try connection.terminalArguments() }
    }

    @Test func unregisteredAndMismatchedMachineRecipesAreRejected() async throws {
        let machine = Machine(name: "Mock", host: "mock.invalid")
        let unregistered = SSHConnection(machine: machine) { _, _, _ in
            Issue.record("Unexpected peer invocation"); return Data()
        }
        await #expect(throws: ExtensionPeerError.self) { try await unregistered.connect() }
        try await MachineRegistry.refresh { _, _, _ in
            try JSONSerialization.data(withJSONObject: [
                "machines": [
                    [
                        "id": machine.id.uuidString, "name": machine.name,
                        "sshTarget": machine.sshTarget,
                    ]
                ]
            ])
        }
        defer { MachineRegistry.shutdown() }
        let connection = SSHConnection(machine: machine) { _, _, _ in
            try JSONSerialization.data(withJSONObject: [
                "machineID": UUID().uuidString, "name": machine.name,
                "sshTarget": machine.sshTarget, "sshArguments": [machine.sshTarget],
                "controlPath": "/tmp/mock", "platform": "linux",
            ])
        }
        await #expect(throws: ExtensionPeerError.self) { try await connection.connect() }
        #expect(connection.controlSocketPath.isEmpty)
    }

    @Test func cancellingTheNativeRelayReapsItsSyntheticPtyProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quinjet-native-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let specification = QuinjetPTYTerminalBridgeSpecification(
            controller: .init(
                executable: "/usr/bin/python3",
                arguments: [
                    "-c",
                    "import os,time; open('" + pidFile.path
                        + "','w').write(str(os.getpid())); time.sleep(60)",
                ], environment: []), transport: .terminal)
        let deadline = Date().addingTimeInterval(5)
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer { try? output.close() }
        let status = try QuinjetPTYNativeTerminalBridge.relay(
            specification: specification, input: pipe.fileHandleForReading, output: output,
            dimensions: { .init(columns: 80, rows: 24, cellWidth: 8, cellHeight: 16) },
            cancelled: { FileManager.default.fileExists(atPath: pidFile.path) || Date() > deadline }
        )
        #expect(status == 130)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(kill(-pid, 0) == -1 && errno == ESRCH)
    }
}
