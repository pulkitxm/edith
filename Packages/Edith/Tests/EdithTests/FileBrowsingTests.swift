import Foundation
import Testing

@testable import EdithKit

@Suite struct FileSortingTests {
    private let entries = [
        RemoteFileEntry(
            name: "readme.md", path: "/a/readme.md", kind: .file, sizeBytes: 300,
            modified: Date(timeIntervalSince1970: 300)),
        RemoteFileEntry(
            name: "Apple", path: "/a/Apple", kind: .directory, sizeBytes: 4096,
            modified: Date(timeIntervalSince1970: 100)),
        RemoteFileEntry(
            name: "banana.txt", path: "/a/banana.txt", kind: .file, sizeBytes: 100,
            modified: Date(timeIntervalSince1970: 200)),
        RemoteFileEntry(
            name: "zebra", path: "/a/zebra", kind: .directory, sizeBytes: 4096,
            modified: Date(timeIntervalSince1970: 400)),
    ]

    @Test func foldersComeFirstRegardlessOfKey() {
        for key in FileSortKey.allCases {
            for ascending in [true, false] {
                let sorted = FileSorting.sort(entries, by: key, ascending: ascending)
                let leadingAreFolders = sorted.prefix(2).allSatisfy { $0.isDirectory }
                let trailingAreFiles = sorted.suffix(2).allSatisfy { !$0.isDirectory }
                #expect(leadingAreFolders)
                #expect(trailingAreFiles)
            }
        }
    }

    @Test func sortsByNameCaseInsensitively() {
        let sorted = FileSorting.sort(entries, by: .name, ascending: true)
        #expect(sorted.map(\.name) == ["Apple", "zebra", "banana.txt", "readme.md"])
    }

    @Test func sortsBySizeAndDate() {
        let bySize = FileSorting.sort(entries, by: .size, ascending: true)
        #expect(bySize.suffix(2).map(\.name) == ["banana.txt", "readme.md"])
        let byDate = FileSorting.sort(entries, by: .modified, ascending: false)
        #expect(byDate.suffix(2).map(\.name) == ["readme.md", "banana.txt"])
    }

    @Test func descendingReversesWithinGroups() {
        let sorted = FileSorting.sort(entries, by: .name, ascending: false)
        #expect(sorted.map(\.name) == ["zebra", "Apple", "readme.md", "banana.txt"])
    }

    @Test func sortIsStableForEqualKeys() {
        let same = (1...5).map {
            RemoteFileEntry(
                name: "file\($0)", path: "/a/file\($0)", kind: .file, sizeBytes: 10,
                modified: Date(timeIntervalSince1970: 0))
        }
        #expect(
            FileSorting.sort(same, by: .size, ascending: true).map(\.name)
                == ["file1", "file2", "file3", "file4", "file5"])
    }

    @Test func describesKinds() {
        #expect(entries[1].kindDescription == "Folder")
        #expect(entries[0].kindDescription == "MD file")
        #expect(
            RemoteFileEntry(name: "link", path: "/l", kind: .symlink, sizeBytes: 0)
                .kindDescription == "Alias")
        #expect(
            RemoteFileEntry(name: "binary", path: "/b", kind: .file, sizeBytes: 0)
                .kindDescription == "Document")
    }
}

@Suite struct FileSelectionMathTests {
    private let entries = (1...5).map {
        RemoteFileEntry(name: "f\($0)", path: "/p/f\($0)", kind: .file, sizeBytes: 1)
    }

    @Test func rangeSelectionSpansBothDirections() {
        #expect(
            FileSelectionMath.rangeSelection(in: entries, from: "/p/f2", to: "/p/f4")
                == ["/p/f2", "/p/f3", "/p/f4"])
        #expect(
            FileSelectionMath.rangeSelection(in: entries, from: "/p/f4", to: "/p/f2")
                == ["/p/f2", "/p/f3", "/p/f4"])
    }

    @Test func rangeWithoutAnchorSelectsOnlyTarget() {
        #expect(
            FileSelectionMath.rangeSelection(in: entries, from: nil, to: "/p/f3") == ["/p/f3"])
    }

    @Test func toggleAddsAndRemoves() {
        let once = FileSelectionMath.toggled([], path: "/p/f1")
        #expect(once == ["/p/f1"])
        #expect(FileSelectionMath.toggled(once, path: "/p/f1").isEmpty)
    }

    @Test func typeSelectFindsAndCyclesMatches() {
        let items = [
            RemoteFileEntry(name: "alpha", path: "/a", kind: .file, sizeBytes: 0),
            RemoteFileEntry(name: "Apple", path: "/b", kind: .file, sizeBytes: 0),
            RemoteFileEntry(name: "beta", path: "/c", kind: .file, sizeBytes: 0),
        ]
        #expect(FileSelectionMath.typeSelectMatch(in: items, prefix: "a", after: nil) == "/a")
        #expect(FileSelectionMath.typeSelectMatch(in: items, prefix: "a", after: "/a") == "/b")
        #expect(FileSelectionMath.typeSelectMatch(in: items, prefix: "a", after: "/b") == "/a")
        #expect(FileSelectionMath.typeSelectMatch(in: items, prefix: "be", after: nil) == "/c")
        #expect(FileSelectionMath.typeSelectMatch(in: items, prefix: "z", after: nil) == nil)
    }
}

@Suite struct FileOperationsTests {
    private let entries = [
        RemoteFileEntry(name: "untitled folder", path: "/a", kind: .directory, sizeBytes: 0),
        RemoteFileEntry(name: "notes.txt", path: "/b", kind: .file, sizeBytes: 0),
    ]

    @Test func newFolderNameAvoidsCollisions() {
        #expect(FileOperations.newFolderName(existing: []) == "untitled folder")
        #expect(FileOperations.newFolderName(existing: entries) == "untitled folder 2")
    }

    @Test func duplicateNameKeepsExtension() {
        #expect(
            FileOperations.duplicateName(of: "notes.txt", existing: entries) == "notes copy.txt")
        #expect(FileOperations.duplicateName(of: "README", existing: []) == "README copy")
    }

    @Test func duplicateNameIncrementsWhenTaken() {
        let taken = [
            RemoteFileEntry(name: "a copy.txt", path: "/x", kind: .file, sizeBytes: 0)
        ]
        #expect(FileOperations.duplicateName(of: "a.txt", existing: taken) == "a copy 2.txt")
    }

    @Test func trashCommandFollowsFreedesktopLayout() {
        let command = FileOperations.trashCommand(paths: ["/home/p/a b.txt"])
        #expect(command.contains(".local/share/Trash/files"))
        #expect(command.contains(".local/share/Trash/info"))
        #expect(command.contains("trashinfo"))
        #expect(command.contains("'/home/p/a b.txt'"))
        #expect(!command.contains("rm -rf"))
    }

    @Test func destructiveCommandsQuotePaths() {
        #expect(
            FileOperations.deleteCommand(paths: ["/a b", "/c"]) == "rm -rf '/a b' /c")
        #expect(
            FileOperations.moveCommand(paths: ["/a b"], toDirectory: "/dest dir")
                == "mv '/a b' '/dest dir'")
        #expect(
            FileOperations.copyCommand(paths: ["/a"], toDirectory: "/d") == "cp -a /a /d")
    }

    @Test func renameRefusesToClobberAndSaysSo() {
        let command = FileOperations.renameCommand(path: "/a/x", to: "/a/y")
        #expect(command == "if [ -e /a/y ]; then exit 17; fi; mv /a/x /a/y")
        #expect(!command.contains("mv -n"))
    }

    @Test func searchAndSpaceCommandsAreQuoted() {
        let search = FileOperations.searchCommand(path: "/my dir", query: "note")
        #expect(search.contains("'/my dir'"))
        #expect(search.contains("'*note*'"))
        #expect(search.contains("head -300"))
        #expect(FileOperations.freeSpaceCommand(path: "/my dir").contains("'/my dir'"))
        #expect(FileOperations.directorySizeCommand(path: "/x").contains("du -sk"))
    }
}

@Suite struct FileViewModeTests {
    @Test func viewModesCarryTitlesAndSymbols() {
        for mode in FileViewMode.allCases {
            #expect(!mode.title.isEmpty)
            #expect(!mode.symbol.isEmpty)
        }
        #expect(FileViewMode.allCases.count == 2)
    }

    @Test func sortKeysAreCodableAndTitled() throws {
        for key in FileSortKey.allCases {
            #expect(!key.title.isEmpty)
            let data = try JSONEncoder().encode(key)
            let decoded = try JSONDecoder().decode(FileSortKey.self, from: data)
            #expect(decoded == key)
        }
    }
}

@Suite struct FilePlacesTests {
    @Test func localSectionsCoverFavoritesAndVolumes() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let sections = FilePlaces.localSections(
            home: home, volumes: [URL(fileURLWithPath: "/Volumes/Backup")])
        #expect(sections.map(\.title) == ["Favorites", "Locations"])
        let favorites = sections[0].places
        #expect(favorites.first?.path == "/Users/tester")
        #expect(favorites.contains { $0.path == "/Users/tester/Downloads" })
        #expect(sections[1].places.contains { $0.name == "Backup" })
        #expect(sections[1].places.first?.path == "/")
    }

    @Test func listingQuotesPathsSoTildeMustBeResolvedFirst() {
        #expect(FileListing.command(path: "~", showHidden: true).contains("'~'"))
        #expect(FilePlaces.homeDirectoryCommand() == "echo $HOME")
    }

    @Test func remoteSectionsUseTheResolvedHome() {
        let sections = FilePlaces.remoteSections(home: "/home/pulkit")
        #expect(sections[0].places.first?.path == "/home/pulkit")
        #expect(sections[0].places.contains { $0.path == "/home/pulkit/Documents" })
        #expect(sections[1].places.contains { $0.path == "/var/log" })
    }
}

@Suite struct FileClipboardTests {
    @Test func copyAndMoveProduceTheRightCommand() {
        let machine = UUID()
        let copy = FileClipboard(paths: ["/a/x", "/a/y"], machineID: machine, operation: .copy)
        #expect(copy.command(intoDirectory: "/dest") == "cp -a /a/x /a/y /dest")
        let move = FileClipboard(paths: ["/a x"], machineID: machine, operation: .move)
        #expect(move.command(intoDirectory: "/dest dir") == "mv '/a x' '/dest dir'")
    }

    @Test func emptyClipboardProducesNoCommand() {
        let clipboard = FileClipboard(paths: [], machineID: UUID(), operation: .copy)
        #expect(clipboard.command(intoDirectory: "/dest") == nil)
    }
}

@Suite struct FileInfoSummaryTests {
    @Test func describesOctalPermissions() {
        #expect(FileInfoSummary.describe(mode: "755") == "755  ·  rwxr-xr-x")
        #expect(FileInfoSummary.describe(mode: "644") == "644  ·  rw-r--r--")
        #expect(FileInfoSummary.describe(mode: "") == "Unknown")
        #expect(FileInfoSummary.describe(mode: "drwxr-xr-x") == "drwxr-xr-x")
    }

    @Test func summarizesAnEntry() {
        let entry = RemoteFileEntry(
            name: "notes.txt", path: "/home/p/notes.txt", kind: .file, sizeBytes: 2048,
            modified: Date(timeIntervalSince1970: 1_754_000_000), mode: "644")
        let summary = FileInfoSummary(entry: entry)
        #expect(summary.kind == "TXT file")
        #expect(summary.size == "2.0 KB")
        #expect(summary.permissions.hasPrefix("644"))
    }

    @Test func foldersCanOverrideSize() {
        let entry = RemoteFileEntry(
            name: "src", path: "/home/p/src", kind: .directory, sizeBytes: 4096)
        #expect(FileInfoSummary(entry: entry).size == "—")
        #expect(FileInfoSummary(entry: entry, sizeOverride: "1.2 GB").size == "1.2 GB")
    }
}

@Suite struct RenameSelectionTests {
    @Test func selectsBaseNameWithoutExtension() {
        let name = "report.final.pdf"
        let range = RenameSelection.baseNameRange(of: name)
        #expect(range.map { String(name[$0]) } == "report.final")
        #expect(RenameSelection.baseNameRange(of: "README") == nil)
    }

    @Test func rejectsInvalidNames() {
        #expect(RenameSelection.isValid("notes.txt"))
        #expect(!RenameSelection.isValid(""))
        #expect(!RenameSelection.isValid("   "))
        #expect(!RenameSelection.isValid("a/b"))
        #expect(!RenameSelection.isValid(".."))
    }
}

@Suite struct DropResolverTests {
    private let machineA = UUID()
    private let machineB = UUID()

    @Test func sameMachineDragMovesUnlessOptionHeld() {
        let payload = MachineItemsPayload(machineID: machineA, paths: ["/a/x"], isLocal: false)
        #expect(
            DropResolver.intent(
                payload: payload, fileURLPaths: [], destinationMachine: machineA,
                optionHeld: false) == .moveWithinMachine(["/a/x"]))
        #expect(
            DropResolver.intent(
                payload: payload, fileURLPaths: [], destinationMachine: machineA,
                optionHeld: true) == .copyWithinMachine(["/a/x"]))
    }

    @Test func crossMachineDragTransfers() {
        let payload = MachineItemsPayload(machineID: machineA, paths: ["/a/x"], isLocal: false)
        #expect(
            DropResolver.intent(
                payload: payload, fileURLPaths: [], destinationMachine: machineB,
                optionHeld: false) == .transferBetweenMachines(from: machineA, paths: ["/a/x"]))
    }

    @Test func externalFilesUpload() {
        #expect(
            DropResolver.intent(
                payload: nil, fileURLPaths: ["/Users/p/a.txt"], destinationMachine: machineA,
                optionHeld: false) == .uploadLocalFiles(["/Users/p/a.txt"]))
        #expect(
            DropResolver.intent(
                payload: nil, fileURLPaths: [], destinationMachine: machineA, optionHeld: false)
                == nil)
    }

    @Test func refusesDropsOntoSelfParentOrDescendant() {
        #expect(!DropResolver.isDropAllowed(paths: ["/a/src"], destination: "/a/src"))
        #expect(!DropResolver.isDropAllowed(paths: ["/a/src"], destination: "/a/src/deep"))
        #expect(!DropResolver.isDropAllowed(paths: ["/a/src/x.txt"], destination: "/a/src"))
        #expect(DropResolver.isDropAllowed(paths: ["/a/src/x.txt"], destination: "/b"))
    }
}

@Suite struct NameConflictTests {
    private let existing = [
        RemoteFileEntry(name: "a.txt", path: "/d/a.txt", kind: .file, sizeBytes: 1),
        RemoteFileEntry(name: "a 2.txt", path: "/d/a 2.txt", kind: .file, sizeBytes: 1),
    ]

    @Test func detectsConflictsAndPicksFreeNames() {
        #expect(
            NameConflicts.conflicting(names: ["a.txt", "b.txt"], existing: existing)
                == ["a.txt"])
        #expect(NameConflicts.uniqueName(for: "a.txt", existing: existing) == "a 3.txt")
        #expect(NameConflicts.uniqueName(for: "b.txt", existing: existing) == "b.txt")
    }

    @Test func buildsMoveCommandsHonouringResolutions() {
        let intent = DropIntent.moveWithinMachine(["/src/a.txt", "/src/b.txt"])
        let replace = NameConflicts.command(
            intent: intent, destination: "/d", resolutions: ["a.txt": .replace],
            existing: existing)
        #expect(
            replace
                == "mv /src/a.txt /d/a.txt.edith-replacing && rm -rf /d/a.txt"
                + " && mv /d/a.txt.edith-replacing /d/a.txt; "
                + "mv /src/b.txt /d/b.txt")

        let skip = NameConflicts.command(
            intent: intent, destination: "/d", resolutions: ["a.txt": .skip], existing: existing)
        #expect(skip == "mv /src/b.txt /d/b.txt")

        let keep = NameConflicts.command(
            intent: intent, destination: "/d", resolutions: ["a.txt": .keepBoth],
            existing: existing)
        #expect(keep?.contains("/d/a 3.txt") == true)
    }

    @Test func copyIntentUsesCopyCommand() {
        let command = NameConflicts.command(
            intent: .copyWithinMachine(["/src/x"]), destination: "/d",
            resolutions: ["x": .keepBoth], existing: [])
        #expect(command == "cp -a /src/x /d/x")
    }

    @Test func skippingEverythingProducesNoCommand() {
        let command = NameConflicts.command(
            intent: .moveWithinMachine(["/src/a.txt"]), destination: "/d",
            resolutions: ["a.txt": .skip], existing: existing)
        #expect(command == nil)
    }
}

@Suite struct ReplaceOntoDirectoryTests {
    @Test func replacingClearsTheTargetSoFoldersAreNotNested() {
        let existing = [
            RemoteFileEntry(name: "docs", path: "/d/docs", kind: .directory, sizeBytes: 0)
        ]
        let command = NameConflicts.command(
            intent: .moveWithinMachine(["/src/docs"]), destination: "/d",
            resolutions: ["docs": .replace], existing: existing)
        #expect(
            command
                == "mv /src/docs /d/docs.edith-replacing && rm -rf /d/docs"
                + " && mv /d/docs.edith-replacing /d/docs")
        #expect(command?.contains("mv -f") == false)
        #expect(command?.hasPrefix("rm -rf") == false)
    }

    @Test func anUnresolvedNameNeverDeletesAnything() {
        let existing = [
            RemoteFileEntry(name: "docs", path: "/d/docs", kind: .directory, sizeBytes: 0)
        ]
        let command = NameConflicts.command(
            intent: .moveWithinMachine(["/src/docs"]), destination: "/d",
            resolutions: [:], existing: existing)
        #expect(command?.contains("rm -rf") == false)
        #expect(command == "mv /src/docs '/d/docs 2'")
    }

    @Test func replaceStagesTheArrivalBeforeRemovingTheTarget() {
        let command =
            NameConflicts.command(
                intent: .copyWithinMachine(["/src/docs"]), destination: "/d",
                resolutions: ["docs": .replace],
                existing: [
                    RemoteFileEntry(name: "docs", path: "/d/docs", kind: .directory, sizeBytes: 0)
                ]) ?? ""
        let stage = command.range(of: "cp -a /src/docs /d/docs.edith-replacing")
        let removal = command.range(of: "rm -rf /d/docs ")
        #expect(stage != nil)
        #expect(removal != nil)
        #expect(stage!.lowerBound < removal!.lowerBound)
    }

    @Test func oneFailureDoesNotAbortTheRest() {
        let command = NameConflicts.command(
            intent: .moveWithinMachine(["/src/a", "/src/b"]), destination: "/d",
            resolutions: ["a": .keepBoth, "b": .keepBoth], existing: [])
        #expect(command?.contains("; ") == true)
        #expect(command?.contains("&& mv /src/b") == false)
    }
}

@Suite struct BatchRenameTests {
    @Test func findAndReplaceAndNumbering() {
        #expect(
            BatchRename.apply(
                names: ["IMG_1.png", "IMG_2.png"], find: "IMG", replace: "Photo",
                numbering: false) == ["Photo_1.png", "Photo_2.png"])
        #expect(
            BatchRename.apply(names: ["a.txt", "b.txt"], find: "", replace: "", numbering: true)
                == ["a 1.txt", "b 2.txt"])
    }
}

@Suite struct FileOperationProgressTests {
    @Test func reportsFractionAndLabel() {
        let single = FileOperationProgress(title: "Moving")
        #expect(single.description == "Moving")
        let many = FileOperationProgress(title: "Moving", completed: 2, total: 5)
        #expect(many.fraction == 0.4)
        #expect(many.description == "Moving (2 of 5)")
    }
}

@Suite struct FleetMathTests {
    private func machine(
        name: String, online: Bool = true, cores: Int, cpu: Double, memTotal: Int64,
        memUsed: Int64, diskTotal: Int64 = 0, diskUsed: Int64 = 0, load: Double = 0
    ) -> MachineSnapshot {
        MachineSnapshot(
            id: UUID(), name: name, isLocal: false, online: online, cores: cores,
            cpuPercent: cpu, memoryTotalKB: memTotal, memoryUsedKB: memUsed,
            diskTotalKB: diskTotal, diskUsedKB: diskUsed, loadOne: load)
    }

    @Test func sumsMemoryAcrossMachines() {
        let fleet = FleetMath.summarize([
            machine(name: "a", cores: 4, cpu: 10, memTotal: 5_000_000, memUsed: 3_000_000),
            machine(name: "b", cores: 8, cpu: 20, memTotal: 15_000_000, memUsed: 5_000_000),
        ])
        #expect(fleet.memoryTotalKB == 20_000_000)
        #expect(fleet.memoryUsedKB == 8_000_000)
        #expect(fleet.memoryPercent == 40)
    }

    @Test func cpuIsWeightedByCoreCount() {
        let fleet = FleetMath.summarize([
            machine(name: "small", cores: 2, cpu: 100, memTotal: 1, memUsed: 0),
            machine(name: "big", cores: 8, cpu: 0, memTotal: 1, memUsed: 0),
        ])
        #expect(fleet.totalCores == 10)
        #expect(fleet.cpuPercent == 20)
    }

    @Test func offlineMachinesAreExcludedFromTotalsButCounted() {
        let fleet = FleetMath.summarize([
            machine(name: "up", cores: 4, cpu: 50, memTotal: 8_000_000, memUsed: 4_000_000),
            machine(
                name: "down", online: false, cores: 4, cpu: 0, memTotal: 8_000_000,
                memUsed: 0),
        ])
        #expect(fleet.machinesOnline == 1)
        #expect(fleet.machinesTotal == 2)
        #expect(fleet.memoryTotalKB == 8_000_000)
        #expect(fleet.alerts.contains { $0.kind == .offline })
    }

    @Test func raisesAlertsForPressure() {
        let alerts = FleetMath.alerts(for: [
            machine(
                name: "full", cores: 4, cpu: 10, memTotal: 100, memUsed: 99,
                diskTotal: 100, diskUsed: 95, load: 12)
        ])
        #expect(alerts.contains { $0.kind == .diskFull })
        #expect(alerts.contains { $0.kind == .memoryPressure })
        #expect(alerts.contains { $0.kind == .highLoad })
    }

    @Test func sortsOnlineFirstThenByPressure() {
        let calm = machine(name: "calm", cores: 4, cpu: 5, memTotal: 100, memUsed: 5)
        let busy = machine(name: "busy", cores: 4, cpu: 95, memTotal: 100, memUsed: 10)
        let offline = machine(
            name: "offline", online: false, cores: 4, cpu: 0, memTotal: 100, memUsed: 0)
        let sorted = FleetMath.sortedByPressure([calm, offline, busy])
        #expect(sorted.map(\.name) == ["busy", "calm", "offline"])
        #expect(FleetMath.busiest([calm, busy, offline])?.name == "busy")
    }

    @Test func emptyFleetIsSafe() {
        let fleet = FleetMath.summarize([])
        #expect(fleet.cpuPercent == 0)
        #expect(fleet.memoryPercent == 0)
        #expect(fleet.alerts.isEmpty)
    }
}

@Suite struct WorkspaceLayoutTests {
    private func layout(machine: UUID) -> WorkspaceLayout {
        WorkspaceLayout.single(machineID: machine, screen: .overview)
    }

    @Test func splittingAddsAPaneAndKeepsRatiosNormalized() {
        let machine = UUID()
        var value = layout(machine: machine)
        let first = value.root.panes[0].id
        value.split(
            paneID: first, side: .right,
            target: PaneTarget(machineID: machine, screen: .docker))
        #expect(value.paneCount == 2)
        guard case let .split(split) = value.root else {
            Issue.record("expected a split root")
            return
        }
        #expect(split.axis == .horizontal)
        #expect(abs(split.ratios.reduce(0, +) - 1) < 0.0001)
    }

    @Test func closingCollapsesBackToASinglePane() {
        let machine = UUID()
        var value = layout(machine: machine)
        let first = value.root.panes[0].id
        value.split(
            paneID: first, side: .bottom,
            target: PaneTarget(machineID: machine, screen: .terminal))
        let second = value.root.panes.first { $0.id != first }?.id
        value.closePane(second ?? first)
        #expect(value.paneCount == 1)
        if case .split = value.root { Issue.record("root should collapse to a pane") }
    }

    @Test func lastPaneCannotBeClosed() {
        var value = layout(machine: UUID())
        value.closePane(value.root.panes[0].id)
        #expect(value.paneCount == 1)
    }

    @Test func tiledPresetsMakeOnePanePerMachine() {
        let ids = [UUID(), UUID(), UUID()]
        let tiled = WorkspaceLayout.tiled(machineIDs: ids, screen: .docker, name: "Docker")
        #expect(tiled?.paneCount == 3)
        #expect(tiled?.subscribedMachines() == Set(ids))
        #expect(tiled?.allTargets.allSatisfy { $0.screen == .docker } == true)
        #expect(WorkspaceLayout.tiled(machineIDs: [], screen: .docker, name: "x") == nil)
    }

    @Test func retargetSwapsEveryPaneOfAMachine() {
        let old = UUID()
        let new = UUID()
        var value = WorkspaceLayout.tiled(
            machineIDs: [old, old], screen: .overview, name: "pair")!
        value.retarget(from: old, to: new)
        #expect(value.subscribedMachines() == [new])
    }

    @Test func layoutSurvivesEncodingRoundTrip() throws {
        let machine = UUID()
        var value = layout(machine: machine)
        value.split(
            paneID: value.root.panes[0].id, side: .right,
            target: PaneTarget(machineID: machine, screen: .files))
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        #expect(decoded == value)
    }

    @Test func geometryDividesTheRectByRatios() {
        let machine = UUID()
        var value = layout(machine: machine)
        value.split(
            paneID: value.root.panes[0].id, side: .right,
            target: PaneTarget(machineID: machine, screen: .docker))
        var frames: [UUID: CGRect] = [:]
        WorkspaceGeometry.frames(
            node: value.root, in: CGRect(x: 0, y: 0, width: 1000, height: 500), gap: 0,
            into: &frames)
        #expect(frames.count == 2)
        #expect(frames.values.allSatisfy { $0.width == 500 })
        #expect(frames.values.allSatisfy { $0.height == 500 })
    }

    @Test func storeTracksTheCurrentLayout() {
        var store = WorkspaceStore()
        let one = layout(machine: UUID())
        let two = layout(machine: UUID())
        store.upsert(one)
        store.upsert(two)
        #expect(store.current?.id == two.id)
        store.remove(two.id)
        #expect(store.current?.id == one.id)
    }
}

@Suite struct CaseInsensitiveConflictTests {
    private let existing = [
        RemoteFileEntry(name: "README", path: "/d/README", kind: .file, sizeBytes: 1),
        RemoteFileEntry(
            name: "archive.tar.gz", path: "/d/archive.tar.gz", kind: .file, sizeBytes: 2),
    ]

    @Test func aDifferentlyCasedNameCollidesOnACaseInsensitiveVolume() {
        #expect(
            NameConflicts.conflicting(
                names: ["readme"], existing: existing, caseInsensitive: true) == ["readme"])
        #expect(
            NameConflicts.conflicting(
                names: ["readme"], existing: existing, caseInsensitive: false
            ).isEmpty)
    }

    @Test func decomposedAndComposedSpellingsCollide() {
        let composed = "café.txt"
        let decomposed = "cafe\u{0301}.txt"
        let folder = [
            RemoteFileEntry(name: composed, path: "/d/\(composed)", kind: .file, sizeBytes: 1)
        ]
        #expect(
            NameConflicts.conflicting(names: [decomposed], existing: folder) == [decomposed])
    }

    @Test func twoIncomingNamesThatCollideWithEachOtherAreBothReported() {
        let clashes = NameConflicts.conflicting(
            names: ["notes.txt", "NOTES.TXT"], existing: [], caseInsensitive: true)
        #expect(clashes == ["NOTES.TXT"])
    }

    @Test func keepBothPreservesACompoundExtension() {
        #expect(
            NameConflicts.uniqueName(for: "archive.tar.gz", existing: existing)
                == "archive 2.tar.gz")
        #expect(NameFolding.split("archive.tar.gz").suffix == ".tar.gz")
        #expect(NameFolding.split("notes.txt").suffix == ".txt")
        #expect(NameFolding.split("Makefile").suffix == "")
    }

    @Test func keepBothDoesNotHandTwoItemsTheSameName() {
        let command =
            NameConflicts.command(
                intent: .moveWithinMachine(["/a/report.txt", "/b/REPORT.TXT"]),
                destination: "/d",
                resolutions: ["report.txt": .keepBoth, "REPORT.TXT": .keepBoth],
                existing: [
                    RemoteFileEntry(
                        name: "report.txt", path: "/d/report.txt", kind: .file, sizeBytes: 1)
                ]) ?? ""
        #expect(command.contains("/d/report 2.txt"))
        #expect(command.contains("/d/REPORT 3.TXT"))
        #expect(!command.contains("rm -rf"))
    }
}
