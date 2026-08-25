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

    private func waitForFile(_ file: URL, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return FileManager.default.fileExists(atPath: file.path)
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

    @Test func everyRegistryWriterWaitsForTheCrossProcessLock() throws {
        let (files, root) = files()
        defer { try? FileManager.default.removeItem(at: root) }
        var machineToUpdate = Machine(name: "Update", host: "update")
        let machineToRemove = Machine(name: "Remove", host: "remove")
        let machineToAdd = Machine(name: "Add", host: "add")
        let forwardToRemove = PortForward(
            machineID: machineToUpdate.id, localPort: 8000, remotePort: 80)
        let forwardRemovedWithMachine = PortForward(
            machineID: machineToRemove.id, localPort: 8001, remotePort: 81)
        let forwardToAdd = PortForward(
            machineID: machineToUpdate.id, localPort: 8002, remotePort: 82)
        var snippetToUpdate = CommandSnippet(
            machineID: machineToUpdate.id, title: "Update", command: "before")
        let snippetToRemove = CommandSnippet(
            machineID: machineToUpdate.id, title: "Remove", command: "remove")
        let snippetRemovedWithMachine = CommandSnippet(
            machineID: machineToRemove.id, title: "Cascade", command: "cascade")
        let snippetToAdd = CommandSnippet(
            machineID: machineToUpdate.id, title: "Add", command: "add")
        MachineRegistry.add(machineToUpdate, files)
        MachineRegistry.add(machineToRemove, files)
        MachineRegistry.addForward(forwardToRemove, files)
        MachineRegistry.addForward(forwardRemovedWithMachine, files)
        MachineRegistry.addSnippet(snippetToUpdate, files)
        MachineRegistry.addSnippet(snippetToRemove, files)
        MachineRegistry.addSnippet(snippetRemovedWithMachine, files)
        machineToUpdate.name = "Updated"
        snippetToUpdate.command = "after"
        let updatedMachine = machineToUpdate
        let updatedSnippet = snippetToUpdate

        let ready = root.appendingPathComponent("lock-ready")
        let release = root.appendingPathComponent("lock-release")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [
            "-e",
            """
            lock = File.open(ARGV.fetch(0), File::RDWR | File::CREAT, 0600)
            lock.flock(File::LOCK_EX)
            File.write(ARGV.fetch(1), "ready")
            sleep 0.01 until File.exist?(ARGV.fetch(2))
            """,
            MachineRegistry.lockURL(files).path, ready.path, release.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? Data().write(to: release)
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        try #require(waitForFile(ready))

        let completed = DispatchSemaphore(value: 0)
        let operations: [@Sendable () -> Void] = [
            { _ = MachineRegistry.add(machineToAdd, files) },
            { _ = MachineRegistry.update(updatedMachine, files) },
            { _ = MachineRegistry.remove(id: machineToRemove.id, files) },
            { _ = MachineRegistry.addForward(forwardToAdd, files) },
            { _ = MachineRegistry.removeForward(id: forwardToRemove.id, files) },
            { _ = MachineRegistry.addSnippet(snippetToAdd, files) },
            { _ = MachineRegistry.updateSnippet(updatedSnippet, files) },
            { _ = MachineRegistry.removeSnippet(id: snippetToRemove.id, files) },
        ]
        for operation in operations {
            DispatchQueue.global().async {
                operation()
                completed.signal()
            }
        }

        #expect(completed.wait(timeout: .now() + .milliseconds(300)) == .timedOut)
        try Data().write(to: release)
        for _ in operations {
            #expect(completed.wait(timeout: .now() + .seconds(5)) == .success)
        }
        process.waitUntilExit()

        let contents = MachineRegistry.load(files)
        #expect(Set(contents.machines.map(\.id)) == [updatedMachine.id, machineToAdd.id])
        #expect(contents.machines.first(where: { $0.id == updatedMachine.id })?.name == "Updated")
        #expect(contents.forwards.map(\.id) == [forwardToAdd.id])
        #expect(Set(contents.snippets.map(\.id)) == [updatedSnippet.id, snippetToAdd.id])
        #expect(
            contents.snippets.first(where: { $0.id == updatedSnippet.id })?.command == "after")
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
