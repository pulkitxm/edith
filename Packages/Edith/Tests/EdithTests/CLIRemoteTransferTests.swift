import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite(.serialized) struct CLIRemoteTransferTests {
    @Test func plainDryRunPrintsTheResolvedPlan() async throws {
        try await CLIProbe.inWorld { world in
            let source = world.sandbox.appendingPathComponent("plain-source.txt")
            let destination = world.sandbox.appendingPathComponent("plain-destination")
            try Data("source".utf8).write(to: source)
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            let machine = Machine(name: "Box", host: "box.example")
            CLIEnvironment.remoteTransferTarget = { _ in
                CLITransferTarget(
                    machine: machine,
                    endpoint: .local(machineID: machine.id, name: machine.name))
            }

            let result = await CLIProbe.capture([
                "machines", "files", "get-many", "box", source.path,
                "--to", destination.path, "--dry-run",
            ])

            #expect(result.code == 0)
            #expect(result.stdoutLines.first == "would download 1 item(s)")
            #expect(
                result.stdout.contains(
                    "\(source.path) -> \(destination.path)/plain-source.txt"))
            #expect(result.stderr.isEmpty)
        }
    }

    @Test func getManyDryRunReportsStableTargetsWithoutWriting() async throws {
        try await CLIProbe.inWorld { world in
            let source = world.sandbox.appendingPathComponent("source")
            let destination = world.sandbox.appendingPathComponent("destination")
            try FileManager.default.createDirectory(
                at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            try Data("new".utf8).write(to: source.appendingPathComponent("report.txt"))
            try Data("notes".utf8).write(to: source.appendingPathComponent("notes.txt"))
            try Data("old".utf8).write(to: destination.appendingPathComponent("report.txt"))
            let machine = Machine(name: "Box", host: "box.example")
            CLIEnvironment.remoteTransferTarget = { _ in
                CLITransferTarget(
                    machine: machine,
                    endpoint: .local(machineID: machine.id, name: machine.name))
            }

            let result = await CLIProbe.capture([
                "machines", "files", "get-many", "box",
                source.appendingPathComponent("report.txt").path,
                source.appendingPathComponent("notes.txt").path,
                "--to", destination.path, "--dry-run", "--json",
            ])

            #expect(result.code == 0)
            #expect(
                result.object?["operation"] as? String
                    == RemoteTransferOperation.downloadSelection.descriptor.id.rawValue)
            #expect(result.object?["executed"] as? Bool == false)
            let items = result.object?["items"] as? [[String: Any]]
            #expect(
                items?.map { $0["destination"] as? String } == [
                    destination.appendingPathComponent("report 2.txt").path,
                    destination.appendingPathComponent("notes.txt").path,
                ])
            #expect(
                !FileManager.default.fileExists(
                    atPath: destination.appendingPathComponent("notes.txt").path))
        }
    }

    @Test func replacementNeedsYesAndThenExecutesTheSamePlan() async throws {
        try await CLIProbe.inWorld { world in
            let source = world.sandbox.appendingPathComponent("source")
            let destination = world.sandbox.appendingPathComponent("destination")
            try FileManager.default.createDirectory(
                at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            let sourceFile = source.appendingPathComponent("report.txt")
            let destinationFile = destination.appendingPathComponent("report.txt")
            try Data("new".utf8).write(to: sourceFile)
            try Data("old".utf8).write(to: destinationFile)
            let machine = Machine(name: "Box", host: "box.example")
            CLIEnvironment.remoteTransferTarget = { _ in
                CLITransferTarget(
                    machine: machine,
                    endpoint: .local(machineID: machine.id, name: machine.name))
            }

            let preview = await CLIProbe.capture([
                "machines", "files", "get-many", "box", sourceFile.path,
                "--to", destination.path, "--replace", "--json",
            ])

            #expect(preview.code == 0)
            #expect(preview.object?["requiresConfirmation"] as? Bool == true)
            #expect(preview.object?["executed"] as? Bool == false)
            #expect(try String(contentsOf: destinationFile, encoding: .utf8) == "old")

            let execution = await CLIProbe.capture([
                "machines", "files", "get-many", "box", sourceFile.path,
                "--to", destination.path, "--replace", "--yes", "--json",
            ])

            #expect(execution.code == 0)
            #expect(execution.object?["executed"] as? Bool == true)
            #expect(try String(contentsOf: destinationFile, encoding: .utf8) == "new")
        }
    }

    @Test func failedJSONItemIncludesItsResolvedDestination() async throws {
        try await CLIProbe.inWorld { world in
            let destination = world.sandbox.appendingPathComponent("destination")
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: destination.appendingPathComponent("report.txt"))
            let machine = Machine(name: "Box", host: "box.example")
            CLIEnvironment.remoteTransferTarget = { _ in
                CLITransferTarget(
                    machine: machine,
                    endpoint: RemoteTransferEndpoint(
                        machineID: machine.id, name: machine.name, list: { _ in [] },
                        fetch: { _, _ in
                            throw RemoteTransferError.listingFailed("read refused")
                        }, store: { _, _, _ in }))
            }

            let result = await CLIProbe.capture([
                "machines", "files", "get-many", "box", "/srv/report.txt",
                "--to", destination.path, "--json",
            ])

            #expect(result.code == ExitCodes.failure)
            let failures = result.object?["failures"] as? [[String: Any]]
            #expect(failures?.first?["source"] as? String == "/srv/report.txt")
            #expect(
                failures?.first?["destination"] as? String
                    == destination.appendingPathComponent("report 2.txt").path)
            #expect(failures?.first?["message"] as? String == "read refused")
        }
    }

    @Test func crossMachineTransferExecutesThroughInjectedEndpoints() async throws {
        try await CLIProbe.inWorld { world in
            let sourceRoot = world.sandbox.appendingPathComponent("source")
            let destinationRoot = world.sandbox.appendingPathComponent("destination")
            try FileManager.default.createDirectory(
                at: sourceRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: destinationRoot, withIntermediateDirectories: true)
            let sourceFile = sourceRoot.appendingPathComponent("payload.txt")
            try Data("payload".utf8).write(to: sourceFile)
            let sourceMachine = Machine(name: "Source", host: "source.example")
            let destinationMachine = Machine(name: "Destination", host: "destination.example")
            let targets = [
                "source": CLITransferTarget(
                    machine: sourceMachine,
                    endpoint: .local(machineID: sourceMachine.id, name: sourceMachine.name)),
                "destination": CLITransferTarget(
                    machine: destinationMachine,
                    endpoint: .local(
                        machineID: destinationMachine.id, name: destinationMachine.name)),
            ]
            CLIEnvironment.remoteTransferTarget = { query in
                guard let target = targets[query] else {
                    throw CLIFailure.notFound("no machine named \(query)")
                }
                return target
            }

            let result = await CLIProbe.capture([
                "machines", "files", "transfer", "source", "destination", sourceFile.path,
                "--into", destinationRoot.path, "--json",
            ])

            #expect(result.code == 0)
            #expect(
                result.object?["operation"] as? String
                    == RemoteTransferOperation.transferBetweenMachines.descriptor.id.rawValue)
            #expect(result.object?["sourceMachine"] as? String == "Source")
            #expect(result.object?["destinationMachine"] as? String == "Destination")
            #expect(result.object?["executed"] as? Bool == true)
            #expect(
                try String(
                    contentsOf: destinationRoot.appendingPathComponent("payload.txt"),
                    encoding: .utf8) == "payload")
        }
    }

    @Test func transferRejectsTheSameMachineBeforeListingOrWriting() async {
        await CLIProbe.inWorld { world in
            let machine = Machine(name: "Box", host: "box.example")
            CLIEnvironment.remoteTransferTarget = { _ in
                CLITransferTarget(
                    machine: machine,
                    endpoint: .local(machineID: machine.id, name: machine.name))
            }

            let result = await CLIProbe.capture([
                "machines", "files", "transfer", "box", "box", "/tmp/x",
                "--into", world.sandbox.path, "--json",
            ])

            #expect(result.code == ExitCodes.failure)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("same machine"))
        }
    }

    @Test func transferStopsWhenDestinationListingFails() async {
        await CLIProbe.inWorld { _ in
            let sourceMachine = Machine(name: "Source", host: "source.example")
            let destinationMachine = Machine(name: "Destination", host: "destination.example")
            let source = RemoteTransferEndpoint(
                machineID: sourceMachine.id, name: sourceMachine.name, list: { _ in [] },
                fetch: { _, _ in }, store: { _, _, _ in })
            let destination = RemoteTransferEndpoint(
                machineID: destinationMachine.id, name: destinationMachine.name,
                list: { _ in throw RemoteTransferError.listingFailed("list refused") },
                fetch: { _, _ in }, store: { _, _, _ in })
            CLIEnvironment.remoteTransferTarget = { query in
                if query == "source" {
                    return CLITransferTarget(machine: sourceMachine, endpoint: source)
                }
                return CLITransferTarget(machine: destinationMachine, endpoint: destination)
            }

            let result = await CLIProbe.capture([
                "machines", "files", "transfer", "source", "destination", "/tmp/x",
                "--into", "/archive", "--dry-run", "--json",
            ])

            #expect(result.code == ExitCodes.failure)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("list refused"))
        }
    }
}
