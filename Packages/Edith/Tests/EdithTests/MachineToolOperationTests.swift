import Foundation
import Testing

@testable import EdithKit

@Suite struct MachineToolOperationTests {
    @Test func descriptorsCoverTheTwelveToolOperations() {
        let descriptors =
            MachineForwardOperation.allCases.map(\.descriptor)
            + MachineSnippetOperation.allCases.map(\.descriptor)
            + MachineServiceOperation.allCases.map(\.descriptor)
            + MachineProcessOperation.allCases.map(\.descriptor)
            + MachineDockerPauseOperation.allCases.map(\.descriptor)
        #expect(descriptors.count == 12)
        #expect(
            Set(descriptors.map(\.cli))
                == [
                    ["machines", "forwards", "add"],
                    ["machines", "forwards", "rm"],
                    ["machines", "forwards", "on"],
                    ["machines", "forwards", "off"],
                    ["machines", "snippets", "add"],
                    ["machines", "snippets", "rm"],
                    ["machines", "services", "start"],
                    ["machines", "services", "stop"],
                    ["machines", "services", "restart"],
                    ["machines", "kill"],
                    ["machines", "docker", "pause"],
                    ["machines", "docker", "unpause"],
                ])
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(MachineProcessOperation.terminate.descriptor.requiresPreview)
        #expect(descriptors.allSatisfy(UserOperationCatalog.descriptors.contains))
    }

    @Test func forwardOperationsValidatePersistAndControlOneForward() async throws {
        let machineID = UUID()
        let forward = PortForward(machineID: machineID, localPort: 8080, remotePort: 80)
        var added: PortForward?
        var removed: UUID?
        var active: Bool?
        var notifications = 0

        let add = await MachineForwardOperationExecution.perform(
            .add, forward: forward, existing: [],
            persistAdd: { added = $0 }, persistRemove: { removed = $0 },
            notify: { notifications += 1 })
        #expect(try add.get().operation == .add)
        #expect(added == forward)
        #expect(notifications == 1)

        let enable = await MachineForwardOperationExecution.perform(
            .enable, forward: forward,
            setActive: { candidate, value in
                #expect(candidate == forward)
                active = value
                return nil
            })
        #expect(try enable.get().active == true)
        #expect(active == true)

        let remove = await MachineForwardOperationExecution.perform(
            .remove, forward: forward, persistAdd: { added = $0 },
            persistRemove: { removed = $0 },
            setActive: { _, value in
                active = value
                return nil
            }, notify: { notifications += 1 })
        #expect(try remove.get().operation == .remove)
        #expect(active == false)
        #expect(removed == forward.id)
        #expect(notifications == 2)
    }

    @Test func forwardOperationsRejectInvalidAndDuplicatePorts() async {
        let machineID = UUID()
        let existing = PortForward(machineID: machineID, localPort: 8080, remotePort: 80)
        let duplicate = PortForward(machineID: machineID, localPort: 8080, remotePort: 443)
        let invalid = PortForward(machineID: machineID, localPort: 0, remotePort: 80)

        let duplicated = await MachineForwardOperationExecution.perform(
            .add, forward: duplicate, existing: [existing])
        guard case let .failure(error as MachineForwardOperationError) = duplicated else {
            Issue.record("duplicate local port should fail")
            return
        }
        #expect(error == .duplicateLocalPort(8080))

        let rejected = await MachineForwardOperationExecution.perform(.add, forward: invalid)
        guard case let .failure(error as MachineForwardOperationError) = rejected else {
            Issue.record("invalid port should fail")
            return
        }
        #expect(error == .invalidPort(0))
    }

    @Test func snippetOperationsValidateAndPersist() throws {
        let snippet = CommandSnippet(title: "logs", command: "journalctl -xe")
        var added: CommandSnippet?
        var removed: UUID?
        var notifications = 0

        let add = MachineSnippetOperationExecution.perform(
            .add, snippet: snippet, persistAdd: { added = $0 },
            persistRemove: { removed = $0 }, notify: { notifications += 1 })
        #expect(try add.get().snippet == snippet)
        #expect(added == snippet)

        let remove = MachineSnippetOperationExecution.perform(
            .remove, snippet: snippet, persistAdd: { added = $0 },
            persistRemove: { removed = $0 }, notify: { notifications += 1 })
        #expect(try remove.get().operation == .remove)
        #expect(removed == snippet.id)
        #expect(notifications == 2)

        let empty = MachineSnippetOperationExecution.perform(
            .add, snippet: CommandSnippet(title: "logs", command: " "))
        guard case let .failure(error as MachineSnippetOperationError) = empty else {
            Issue.record("blank commands should fail")
            return
        }
        #expect(error == .missingCommand)
    }

    @Test func serviceExecutionBuildsThePrivilegedCommand() async throws {
        let password = Data("secret\n".utf8)
        var request: (String, Data?, TimeInterval)?
        let result = await MachineServiceOperationExecution.perform(
            .restart, unit: "nginx.service", sudoPassword: password,
            using: { command, stdin, timeout in
                request = (command, stdin, timeout)
                return .success("done")
            })
        #expect(try result.get().output == "done")
        #expect(
            request?.0
                == ServiceCommands.action(
                    "restart", unit: "nginx.service", withSudoPassword: true))
        #expect(request?.1 == password)
        #expect(request?.2 == 60)
    }

    @Test func processExecutionNormalizesSignalsAndReportsExitedProcesses() async throws {
        var request: (String, TimeInterval)?
        let result = await MachineProcessOperationExecution.perform(
            pid: 42, signal: "sigterm",
            using: { command, timeout in
                request = (command, timeout)
                return .success(ProcessCommands.goneMarker)
            })
        let outcome = try result.get()
        #expect(outcome.signal == "TERM")
        #expect(outcome.alreadyExited)
        #expect(request?.0 == ProcessCommands.kill(pid: 42, signal: "TERM"))
        #expect(request?.1 == 30)

        let invalid = await MachineProcessOperationExecution.perform(
            pid: 0, signal: "TERM", using: { _, _ in .success("") })
        guard case let .failure(error as MachineProcessOperationError) = invalid else {
            Issue.record("invalid pid should fail")
            return
        }
        #expect(error == .invalidPID(0))
    }

    @Test func dockerPauseExecutionUsesOneTypedLifecycleCommand() async throws {
        var request: (String, TimeInterval)?
        let result = await MachineDockerPauseOperationExecution.perform(
            .unpause, containerIDs: ["api", "worker"],
            using: { command, timeout in
                request = (command, timeout)
                return .success("")
            })
        #expect(try result.get().operation == .unpause)
        #expect(request?.0 == DockerCommands.lifecycle("unpause", ids: ["api", "worker"]))
        #expect(request?.1 == 120)
    }
}
