import Foundation
import Testing

@testable import EdithKit

@Suite struct MachineFleetOperationTests {
    private func files() -> (MachineRegistry.Files, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachineFleetOperationTests.\(UUID().uuidString)")
        return (
            MachineRegistry.Files(
                machines: root.appendingPathComponent("machines.json"),
                forwards: root.appendingPathComponent("forwards.json"),
                snippets: root.appendingPathComponent("snippets.json")),
            root
        )
    }

    @Test func descriptorsCoverTheEightFleetLifecycleOperations() {
        let descriptors =
            MachineMutationOperation.allCases.map(\.descriptor)
            + MachinePowerOperation.allCases.map(\.descriptor)
            + MachineConnectionOperation.allCases.map(\.descriptor)
        #expect(
            Set(descriptors.map(\.cli))
                == [
                    ["machines", "add"], ["machines", "edit"], ["machines", "rm"],
                    ["machines", "power", "reboot"],
                    ["machines", "power", "shutdown"],
                    ["machines", "power", "wake"], ["machines", "connect"],
                    ["machines", "disconnect"],
                ])
        #expect(Set(descriptors.map(\.id)).count == 8)
        #expect(MachineMutationOperation.remove.descriptor.requiresPreview)
        #expect(MachinePowerOperation.reboot.descriptor.requiresPreview)
        #expect(MachinePowerOperation.shutdown.descriptor.requiresPreview)
        #expect(!MachinePowerOperation.wake.descriptor.requiresPreview)
        #expect(descriptors.allSatisfy(UserOperationCatalog.descriptors.contains))
    }

    @Test func addAndEditPersistCredentialsAndNotify() {
        let (files, root) = files()
        defer { try? FileManager.default.removeItem(at: root) }
        var secrets: [(String, UUID, MachineSecretKind)] = []
        var deletions: [(UUID, MachineSecretKind)] = []
        var notifications = 0
        var machine = Machine(name: "Builder", host: "builder", auth: .password)

        let added = MachineMutationOperationExecution.perform(
            .add, machine: machine,
            secrets: MachineSecretChanges(login: "login", sudoPassword: "sudo"),
            files: files,
            setSecret: { secrets.append(($0, $1, $2)) },
            deleteSecret: { deletions.append(($0, $1)) },
            notify: { notifications += 1 })
        #expect(added.operation == .add)
        #expect(MachineRegistry.machines(files).map(\.id) == [machine.id])
        #expect(MachineRegistry.machines(files).map(\.name) == ["Builder"])
        #expect(secrets.map(\.0) == ["login", "sudo"])
        #expect(secrets.map(\.2) == [.password, .sudoPassword])

        machine.name = "Renamed"
        machine.auth = .keyFile(path: "/tmp/id_ed25519", hasPassphrase: true)
        let edited = MachineMutationOperationExecution.perform(
            .edit, machine: machine,
            secrets: MachineSecretChanges(login: "phrase", forgetSudoPassword: true),
            files: files,
            setSecret: { secrets.append(($0, $1, $2)) },
            deleteSecret: { deletions.append(($0, $1)) },
            notify: { notifications += 1 })
        #expect(edited.operation == .edit)
        #expect(MachineRegistry.machines(files).map(\.id) == [machine.id])
        #expect(MachineRegistry.machines(files).map(\.name) == ["Renamed"])
        #expect(secrets.last?.2 == .passphrase)
        #expect(deletions.map(\.1) == [.sudoPassword])
        #expect(notifications == 2)
    }

    @Test func removalPreviewAndMutationCountRelatedRecords() {
        let (files, root) = files()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine(name: "Builder", host: "builder")
        let other = Machine(name: "Other", host: "other")
        MachineRegistry.add(machine, files)
        MachineRegistry.add(other, files)
        MachineRegistry.addForward(
            PortForward(machineID: machine.id, localPort: 8080, remotePort: 80), files)
        MachineRegistry.addForward(
            PortForward(machineID: other.id, localPort: 9090, remotePort: 90), files)
        MachineRegistry.addSnippet(
            CommandSnippet(machineID: machine.id, title: "logs", command: "journalctl"), files)

        let preview = MachineMutationOperationExecution.removalPreview(machine, files: files)
        #expect(preview.forwardCount == 1)
        #expect(preview.snippetCount == 1)

        var notified = false
        let result = MachineMutationOperationExecution.perform(
            .remove, machine: machine, files: files, notify: { notified = true })
        #expect(result.removal == preview)
        #expect(MachineRegistry.machines(files).map(\.id) == [other.id])
        #expect(MachineRegistry.forwards(files).map(\.machineID) == [other.id])
        #expect(MachineRegistry.snippets(files).isEmpty)
        #expect(notified)
    }

    @Test func powerBuildsThePrivilegedCommandOnce() async throws {
        let machine = Machine(name: "Builder", host: "builder")
        let password = Data("secret\n".utf8)
        var request: (String, Data?, TimeInterval)?
        let outcome = await MachinePowerOperationExecution.perform(
            .reboot, machine: machine,
            sudoPassword: { id in
                #expect(id == machine.id)
                return password
            },
            run: { command, stdin, timeout in
                request = (command, stdin, timeout)
                return .success("")
            })
        let result = try outcome.get()
        #expect(result.operation == .reboot)
        #expect(request?.0 == PowerCommands.reboot(withSudoPassword: true))
        #expect(request?.1 == password)
        #expect(request?.2 == 20)
    }

    @Test func powerTreatsExpectedConnectionLossAsSuccess() async throws {
        let machine = Machine(name: "Builder", host: "builder")
        let outcome = await MachinePowerOperationExecution.perform(
            .shutdown, machine: machine,
            run: { command, _, _ in
                .failure(
                    SSHConnectionError.commandFailed(
                        command: command, status: 255, stderr: "Connection closed"))
            })
        #expect(try outcome.get().operation == .shutdown)
    }

    @Test func wakeUsesLearnedAddressAndReportsFailures() async throws {
        let machine = Machine(name: "Builder", host: "builder")
        var packetSize = 0
        let outcome = await MachinePowerOperationExecution.perform(
            .wake, machine: machine, learnedMACAddress: "aa:bb:cc:dd:ee:ff",
            sendWakePacket: { packet in
                packetSize = packet.count
                return nil
            })
        let result = try outcome.get()
        #expect(result.macAddress == "aa:bb:cc:dd:ee:ff")
        #expect(packetSize == 102)

        let missing = await MachinePowerOperationExecution.perform(.wake, machine: machine)
        guard case let .failure(error as MachinePowerOperationError) = missing else {
            Issue.record("missing wake address should fail")
            return
        }
        #expect(error == .missingWakeAddress("Builder"))
    }

    @Test func connectionExecutionChoosesOneLifecycleAction() async {
        var connected = 0
        var disconnected = 0
        let opened = await MachineConnectionOperationExecution.perform(
            .connect,
            connect: {
                connected += 1
                return 12
            },
            disconnect: { disconnected += 1 })
        #expect(opened.connected)
        #expect(opened.latencyMillis == 12)
        #expect(connected == 1)
        #expect(disconnected == 0)

        let closed = await MachineConnectionOperationExecution.perform(
            .disconnect,
            connect: {
                connected += 1
                return nil
            },
            disconnect: { disconnected += 1 })
        #expect(!closed.connected)
        #expect(connected == 1)
        #expect(disconnected == 1)
    }
}
