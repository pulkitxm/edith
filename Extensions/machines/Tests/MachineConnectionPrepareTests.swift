import Foundation
import Testing
import EdithExtensionSupport
@testable import MachinesExtension

@Suite @MainActor struct MachineConnectionPrepareTests {
    private func fixture() -> (URL, MachineRegistry.Files, Machine) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = MachineRegistry.Files(machines: root.appendingPathComponent("machines.json"))
        let machine = Machine(
            name: "Synthetic builder", host: "builder.invalid", port: 2222,
            username: "test", auth: .keyFile(path: "/synthetic/private key", hasPassphrase: true),
            createdAt: Date(timeIntervalSince1970: 1_791_504_000))
        MachineRegistry.add(machine, files)
        return (root, files, machine)
    }

    private func recipe(_ machine: Machine) throws -> MachineConnectionRecipe {
        let connection = SSHConnection(machine: machine)
        return try MachineConnectionRecipe(
            machine: machine,
            sshArguments: MachineConnectionRecipe.masterOnlyOptions
                + connection.terminalArguments(),
            controlPath: connection.controlSocketPath, platform: .linux)
    }

    private func request(_ machine: Machine) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["machineID": machine.id.uuidString])
    }

    @Test func recipePreservesSavedPortKeyAndOwnedSocketWithoutCredentialBytes() async throws {
        let (root, files, machine) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var preparations = 0
        let peer = MachinePeerService(
            files: files,
            usage: MachineUsageCollectionService(files: files) { _, _ in Data() },
            run: { _, _, _, _ in "" }, forward: { _, _ in true },
            prepareConnection: { selected in
                #expect(selected == machine)
                preparations += 1
                return try self.recipe(selected)
            })
        let data = try await peer.execute("machines.connection.prepare", payload: request(machine))
        let result = try JSONDecoder().decode(MachineConnectionRecipe.self, from: data)
        #expect(result.machineID == machine.id && result.platform == .linux)
        #expect(result.sshArguments.contains("2222"))
        #expect(result.sshArguments.contains("/synthetic/private key"))
        #expect(result.sshTarget == "test@builder.invalid")
        #expect(result.sshArguments.contains(result.controlPath))
        #expect(preparations == 1)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("SSH_ASKPASS") && !text.contains("EDITH_ASKPASS_ACCOUNT"))
        for extra in ["sshArguments", "controlPath", "host", "platform", "password"] {
            let payload = try JSONSerialization.data(withJSONObject: [
                "machineID": machine.id.uuidString, extra: "rejected",
            ])
            await #expect(throws: (any Error).self) {
                try await peer.execute("machines.connection.prepare", payload: payload)
            }
        }
        await #expect(throws: (any Error).self) {
            try await peer.execute(
                "machines.connection.prepare",
                payload: request(Machine(name: "Unknown", host: "unknown.invalid")))
        }
        #expect(preparations == 1)
    }

    @Test func changedRegistryRejectsPreparedConnection() async throws {
        let (root, files, machine) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = MachinePeerService(
            files: files,
            usage: MachineUsageCollectionService(files: files) { _, _ in Data() },
            run: { _, _, _, _ in "" }, forward: { _, _ in true },
            prepareConnection: { selected in
                var changed = selected; changed.port = 2200
                MachineRegistry.update(changed, files)
                return try self.recipe(selected)
            })
        await #expect(throws: (any Error).self) {
            try await peer.execute("machines.connection.prepare", payload: request(machine))
        }
    }

    @Test func cancellationCannotPublishAnInteractiveConnection() async throws {
        let (root, files, machine) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var started = false
        let peer = MachinePeerService(
            files: files,
            usage: MachineUsageCollectionService(files: files) { _, _ in Data() },
            run: { _, _, _, _ in "" }, forward: { _, _ in true },
            prepareConnection: { selected in
                started = true
                try? await Task.sleep(for: .seconds(60))
                return try self.recipe(selected)
            })
        let task = Task {
            try await peer.execute("machines.connection.prepare", payload: request(machine))
        }
        while !started { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        peer.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await peer.execute("machines.connection.prepare", payload: request(machine))
        }
    }
}
