import EdithKit
import Foundation
import Testing

@testable import EdithCLI

@Suite struct MachineFileSharedOperationTests {
    @Test func descriptorsAndPlacementsExactlyCoverTheSixFinderActions() {
        let operations = MachineFileOperation.allCases
        let descriptors = operations.map(\.descriptor)
        let placements = operations.map(\.placement)

        #expect(
            descriptors.map(\.cli)
                == [
                    ["machines", "files", "search"],
                    ["machines", "files", "info"],
                    ["machines", "files", "duplicate"],
                    ["machines", "files", "undo"],
                    ["machines", "files", "rename"],
                    ["machines", "files", "rm"],
                ])
        #expect(
            placements.map(\.action)
                == [
                    "search the folder", "get info on a directory", "duplicate a file",
                    "undo the last move or rename", "rename a file",
                    "move files to the trash",
                ])
        #expect(placements.allSatisfy { $0.surface == "Machine finder" })
        #expect(
            zip(descriptors, placements).allSatisfy { descriptor, placement in
                placement.cli == descriptor.cli + placement.exampleArguments
            })
        #expect(Set(descriptors.map(\.id)).count == 6)
        #expect(Set(descriptors.map(\.cli)).count == 6)
        #expect(MachineFileOperation.remove.descriptor.effect == .destructive)
        #expect(MachineFileOperation.remove.descriptor.requiresPreview)
        #expect(UserOperationCatalog.descriptors.suffix(6) == descriptors[...])
    }

    @Test func searchBuildsTheSharedCommandAndParsesPaths() async throws {
        var command = ""
        var timeout: TimeInterval = 0
        let result = await MachineFileOperationExecution.search(
            path: "/srv/app", query: "swift", limit: 12
        ) { next, seconds in
            command = next
            timeout = seconds
            return .success("/srv/app/A.swift\n/srv/app/B.swift\n")
        }

        let items = try result.get()
        #expect(
            command == FileOperations.searchCommand(path: "/srv/app", query: "swift", limit: 12))
        #expect(timeout == 120)
        #expect(items.map(\.path) == ["/srv/app/A.swift", "/srv/app/B.swift"])
    }

    @Test func localSearchAdapterKeepsEntryKindsWithoutRunningAShell() async throws {
        var ran = false
        let result = await MachineFileOperationExecution.search(
            path: "/tmp", query: "docs", limit: 4,
            localSearch: { path, query, limit in
                #expect(path == "/tmp")
                #expect(query == "docs")
                #expect(limit == 4)
                return .success([MachineFileSearchItem(path: "/tmp/docs", kind: .directory)])
            }
        ) { _, _ in
            ran = true
            return .success("")
        }

        #expect(try result.get() == [MachineFileSearchItem(path: "/tmp/docs", kind: .directory)])
        #expect(!ran)
    }

    @Test func infoConvertsKilobytesToBytes() async throws {
        let result = await MachineFileOperationExecution.info(path: "/srv") { command, timeout in
            #expect(command == FileOperations.directorySizeCommand(path: "/srv"))
            #expect(timeout == 120)
            return .success("42\n")
        }
        #expect(try result.get() == 43_008)
    }

    @Test func duplicateUsesExplicitAndAutomaticDestinations() async throws {
        var commands: [String] = []
        let explicit = await MachineFileOperationExecution.duplicate(
            path: "/a/report.txt", destination: "/a/report copy.txt"
        ) { command, timeout in
            commands.append(command)
            #expect(timeout == 300)
            return .success("/a/report copy.txt")
        }
        let automatic = await MachineFileOperationExecution.duplicate(path: "/a/report.txt") {
            command, timeout in
            commands.append(command)
            #expect(timeout == 300)
            return .success("/a/report copy 2.txt")
        }

        #expect(try explicit.get() == "/a/report copy.txt")
        #expect(try automatic.get() == "/a/report copy 2.txt")
        #expect(commands[0].contains("cp -a /a/report.txt '/a/report copy.txt'"))
        #expect(commands[1].contains("while [ -e \"$target\" ]"))
    }

    @Test func renameValidatesTheNameAndReturnsItsDestination() async throws {
        var command = ""
        let renamed = await MachineFileOperationExecution.rename(
            path: "/a/old.txt", name: "new.txt"
        ) { next, timeout in
            command = next
            #expect(timeout == 300)
            return .success("")
        }
        let invalid = await MachineFileOperationExecution.rename(
            path: "/a/old.txt", name: "../new.txt"
        ) { _, _ in
            Issue.record("invalid rename ran a command")
            return .success("")
        }

        #expect(try renamed.get() == "/a/new.txt")
        #expect(command == FileOperations.renameCommand(path: "/a/old.txt", to: "/a/new.txt"))
        #expect(throws: MachineFileOperationError.invalidName) { try invalid.get() }
    }

    @Test func permanentRemovalPreviewsUntilConfirmed() async throws {
        let plan = MachineFileRemovalPlan(paths: ["/a", "/b"], permanently: true)
        var commands: [String] = []
        let preview = await MachineFileOperationExecution.remove(plan, confirmed: false) {
            command, _ in
            commands.append(command)
            return .success("")
        }
        let applied = await MachineFileOperationExecution.remove(plan, confirmed: true) {
            command, timeout in
            commands.append(command)
            #expect(timeout == 300)
            return .success("")
        }

        #expect(try preview.get() == .preview(plan))
        #expect(try applied.get() == .applied(plan))
        #expect(commands == [FileOperations.deleteCommand(paths: plan.paths)])
    }

    @Test func reversibleRemovalCanUseTheNativeTrashAdapter() async throws {
        let plan = MachineFileRemovalPlan(paths: ["/a"], permanently: false)
        var trashed: [String] = []
        var ran = false
        let result = await MachineFileOperationExecution.remove(
            plan, confirmed: false,
            trash: { paths in
                trashed = paths
                return .success(())
            }
        ) { _, _ in
            ran = true
            return .success("")
        }

        #expect(try result.get() == .applied(plan))
        #expect(trashed == ["/a"])
        #expect(!ran)
    }

    @Test func undoReplaysMovesInReverseOrder() async throws {
        let step = FinderUndoStep(
            label: "Move",
            moves: [
                FinderUndoStep.Move(from: "/a", to: "/x/a"),
                FinderUndoStep.Move(from: "/b", to: "/x/b"),
            ])
        var commands: [String] = []
        let result = await MachineFileOperationExecution.undo(step) { command, timeout in
            commands.append(command)
            #expect(timeout == 300)
            return .success("")
        }

        #expect(try result.get() == ["/a", "/b"])
        #expect(
            commands
                == [
                    FileOperations.renameCommand(path: "/x/b", to: "/b"),
                    FileOperations.renameCommand(path: "/x/a", to: "/a"),
                ])
    }

    @Test func everyFinderParserDeclaresItsExactSharedOperation() {
        #expect(MachinesFilesSearchCommand.operation == .search)
        #expect(MachinesFilesInfoCommand.operation == .info)
        #expect(MachinesFilesDuplicateCommand.operation == .duplicate)
        #expect(MachinesFilesUndoCommand.operation == .undo)
        #expect(MachinesFilesRenameCommand.operation == .rename)
        #expect(MachinesFilesRemoveCommand.operation == .remove)
    }

    @Test func everyFinderDescriptorIsACompletionLeaf() throws {
        for descriptor in MachineFileOperation.allCases.map(\.descriptor) {
            var node = CommandTree.root
            for component in descriptor.cli {
                node = try #require(node.child(component))
            }
            #expect(node.children.isEmpty)
        }
    }

    @Test func permanentRemovalHasStablePlainAndJSONPreviews() async {
        let plain = await CLIProbe.run([
            "machines", "files", "rm", "box", "/a", "/b", "--delete",
        ])
        #expect(plain.code == 0)
        #expect(plain.stdout == "would delete 2 path(s) for good\n")
        #expect(plain.stderr == "nothing was deleted; pass --yes to go ahead\n")

        let json = await CLIProbe.run([
            "machines", "files", "rm", "box", "/a", "/b", "--delete", "--json",
        ])
        #expect(json.code == 0)
        #expect(json.stderr.isEmpty)
        #expect(json.object?["deleted"] as? Bool == false)
        #expect(json.object?["paths"] as? [String] == ["/a", "/b"])
    }
}
