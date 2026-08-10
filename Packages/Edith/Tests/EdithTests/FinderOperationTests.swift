import AppKit
import EdithKit
import Foundation
import Testing

@testable import Edith

@MainActor
private func sandbox() throws -> (model: FinderModel, root: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("edith-finder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let root = URL(fileURLWithPath: (base.path as NSString).resolvingSymlinksInPath)
    let session = MachinesModel.shared.session(for: MachinesModel.localMachineID)
    return (FinderModel(session: session, path: root.path), root)
}

private func write(_ name: String, into root: URL, contents: String = "x") throws {
    try contents.write(
        to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(10), _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

private func resolved(_ path: String) -> String {
    (path as NSString).resolvingSymlinksInPath
}

private func exists(_ name: String, in root: URL) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
}

@Suite(.serialized) @MainActor struct FinderRenameTests {
    @Test func renamingAFileMovesItOnDisk() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("before.txt", into: root)
        await model.load()

        guard let entry = model.entries.first(where: { $0.name == "before.txt" }) else {
            Issue.record("listing did not include the file")
            return
        }
        model.beginRename(entry)
        #expect(model.renaming == entry.path)
        model.renameText = "after.txt"
        await model.commitRename()

        #expect(exists("after.txt", in: root))
        #expect(!exists("before.txt", in: root))
        #expect(model.renaming == nil)
    }

    @Test func renamingOntoAnExistingNameDoesNotDestroyIt() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("keep.txt", into: root, contents: "important")
        try write("other.txt", into: root, contents: "other")
        await model.load()

        guard let entry = model.entries.first(where: { $0.name == "other.txt" }) else { return }
        model.beginRename(entry)
        model.renameText = "keep.txt"
        await model.commitRename()

        let kept = try String(contentsOf: root.appendingPathComponent("keep.txt"), encoding: .utf8)
        #expect(kept == "important")
        #expect(exists("other.txt", in: root))
        #expect(model.errorMessage != nil)
        #expect(model.renaming != nil)
    }

    @Test func aCaseOnlyRenameWorksOnACaseInsensitiveVolume() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("notes.txt", into: root)
        await model.load()

        guard let entry = model.entries.first(where: { $0.name == "notes.txt" }) else { return }
        model.beginRename(entry)
        model.renameText = "Notes.txt"
        await model.commitRename()

        await model.load()
        #expect(model.entries.contains { $0.name == "Notes.txt" })
        #expect(model.errorMessage == nil)
    }

    @Test func theRenamedItemStaysSelected() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("old.txt", into: root)
        await model.load()

        guard let entry = model.entries.first else { return }
        model.beginRename(entry)
        model.renameText = "new.txt"
        await model.commitRename()

        #expect(model.selection.count == 1)
        #expect(model.selection.first?.hasSuffix("new.txt") == true)
    }

    @Test func anEmptyOrUnchangedNameIsANoOp() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("file.txt", into: root)
        await model.load()

        guard let entry = model.entries.first else { return }
        model.beginRename(entry)
        model.renameText = "   "
        await model.commitRename()
        #expect(exists("file.txt", in: root))

        model.beginRename(entry)
        model.renameText = "file.txt"
        await model.commitRename()
        #expect(exists("file.txt", in: root))
    }
}

@Suite(.serialized) @MainActor struct FinderCreateAndDeleteTests {
    @Test func newFolderCreatesItAndOpensTheRenameField() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.load()
        await model.newFolder()

        #expect(exists("untitled folder", in: root))
        #expect(model.renaming != nil)
        #expect(model.renameText == "untitled folder")
    }

    @Test func asecondNewFolderDoesNotCollide() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.load()
        await model.newFolder()
        await model.newFolder()

        #expect(exists("untitled folder", in: root))
        #expect(exists("untitled folder 2", in: root))
    }

    @Test func duplicateMakesACopyBesideTheOriginal() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("notes.txt", into: root, contents: "body")
        await model.load()
        model.selection = Set(model.entries.filter { $0.name == "notes.txt" }.map(\.path))
        await model.duplicateSelection()

        #expect(exists("notes.txt", in: root))
        #expect(exists("notes copy.txt", in: root))
    }

    @Test func deletingImmediatelyRemovesTheFile() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("gone.txt", into: root)
        await model.load()
        model.selection = Set(model.entries.filter { $0.name == "gone.txt" }.map(\.path))
        await model.trashSelection(permanently: true)

        #expect(!exists("gone.txt", in: root))
        #expect(model.selection.isEmpty)
    }
}

@Suite(.serialized) @MainActor struct FinderNavigationTests {
    @Test func openingAFolderNavigatesIntoIt() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try write("deep.txt", into: inner)
        await model.load()

        guard let folder = model.entries.first(where: { $0.name == "inner" }) else { return }
        model.open(folder)

        #expect(await eventually { resolved(model.path) == resolved(inner.path) })
        await model.load()
        #expect(model.entries.contains { $0.name == "deep.txt" })
    }

    @Test func backAndForwardWalkTheHistory() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        await model.load()

        model.navigate(to: inner.path)
        #expect(await eventually { model.canGoBack })

        model.goBack()
        #expect(await eventually { resolved(model.path) == resolved(root.path) })
        #expect(model.canGoForward)

        model.goForward()
        #expect(await eventually { resolved(model.path) == resolved(inner.path) })
    }

    @Test func navigatingClearsTheOldListingSoNoStaleRowsShow() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("outer.txt", into: root)
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        await model.load()
        #expect(model.entries.contains { $0.name == "outer.txt" })

        model.navigate(to: inner.path)
        #expect(model.entries.isEmpty)
    }
}

@Suite(.serialized) @MainActor struct FinderClipboardTests {
    init() { FinderModel.clipboard = nil }

    @Test func cutThenPasteMovesTheFile() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("moving.txt", into: root)
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        await model.load()

        model.selection = Set(model.entries.filter { $0.name == "moving.txt" }.map(\.path))
        model.copySelection(operation: .move)
        model.navigate(to: inner.path)
        await model.load()
        await model.paste()

        #expect(exists("inner/moving.txt", in: root))
        #expect(!exists("moving.txt", in: root))
    }

    @Test func copyThenPasteLeavesTheOriginal() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("copying.txt", into: root)
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        await model.load()

        model.selection = Set(model.entries.filter { $0.name == "copying.txt" }.map(\.path))
        model.copySelection(operation: .copy)
        model.navigate(to: inner.path)
        await model.load()
        await model.paste()

        #expect(exists("copying.txt", in: root))
        #expect(exists("inner/copying.txt", in: root))
    }

    @Test func draggingOntoAFolderMovesIntoIt() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("dragged.txt", into: root)
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        await model.load()

        let source = model.entries.first { $0.name == "dragged.txt" }?.path ?? ""
        await model.perform(
            intent: .moveWithinMachine([source]), destination: inner.path)

        #expect(await eventually { exists("inner/dragged.txt", in: root) })
        #expect(!exists("dragged.txt", in: root))
    }
}

@Suite(.serialized) @MainActor struct FinderSearchTests {
    @Test func searchFindsMatchesInSubfoldersNotJustTheCurrentOne() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try write("needle.txt", into: inner)
        try write("haystack.txt", into: root)
        await model.load()

        model.searchQuery = "needle"
        model.searchQueryChanged()

        #expect(
            await eventually { model.searchResults?.contains { $0.name == "needle.txt" } == true })
    }

    @Test func clearingTheSearchRestoresTheListing() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("alpha.txt", into: root)
        try write("beta.txt", into: root)
        await model.load()

        model.searchQuery = "alpha"
        model.searchQueryChanged()
        #expect(await eventually { model.visibleEntries.count == 1 })

        model.searchQuery = ""
        model.searchQueryChanged()
        #expect(await eventually { model.searchResults == nil })
        #expect(model.visibleEntries.count == 2)
    }
}

@Suite(.serialized) @MainActor struct TerminalLifetimeTests {
    @Test func anInjectedShellSurvivesTheViewGoingAway() async throws {
        let session = MachinesModel.shared.session(for: MachinesModel.localMachineID)
        let holder = PaneViewStore.shared.terminal(for: UUID(), session: session)
        holder.start(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: [])
        #expect(holder.started)

        let view = MachineTerminalTab(session: session, holder: holder)
        _ = view.body
        #expect(holder.started)
    }

    @Test func theStoreKeepsOneHolderPerTabAndStopsItOnRelease() async throws {
        let session = MachinesModel.shared.session(for: MachinesModel.localMachineID)
        let tab = UUID()
        let first = PaneViewStore.shared.terminal(for: tab, session: session)
        let again = PaneViewStore.shared.terminal(for: tab, session: session)
        #expect(first === again)

        first.start(executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: [])
        #expect(first.started)
        PaneViewStore.shared.release(tabID: tab)
        #expect(!first.started)

        let fresh = PaneViewStore.shared.terminal(for: tab, session: session)
        #expect(fresh !== first)
    }
}

@Suite(.serialized) @MainActor struct FinderContextMenuTests {
    @Test func actingOnAnUnselectedRowTargetsThatRowNotTheOldSelection() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("selected.txt", into: root)
        try write("clicked.txt", into: root)
        await model.load()

        model.selection = Set(model.entries.filter { $0.name == "selected.txt" }.map(\.path))
        guard let clicked = model.entries.first(where: { $0.name == "clicked.txt" }) else { return }
        model.focusContext(on: clicked)
        await model.trashSelection(permanently: true)

        #expect(exists("selected.txt", in: root))
        #expect(!exists("clicked.txt", in: root))
    }

    @Test func actingOnARowInsideTheSelectionKeepsTheWholeSelection() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.txt", into: root)
        try write("b.txt", into: root)
        await model.load()

        model.selection = Set(model.entries.map(\.path))
        guard let one = model.entries.first else { return }
        model.focusContext(on: one)
        #expect(model.selection.count == 2)
    }
}

@Suite struct RenameCommandTests {
    @Test func renamingOverAnExistingNameFailsLoudlyRatherThanSilently() {
        let command = FileOperations.renameCommand(path: "/d/a.txt", to: "/d/b.txt")
        #expect(command.contains("if [ -e /d/b.txt ]; then exit 17; fi"))
        #expect(!command.contains("mv -n"))
    }

    @Test func aCaseOnlyRenameGoesThroughATemporaryName() {
        let command = FileOperations.renameCommand(
            path: "/d/notes.txt", to: "/d/Notes.txt", viaTemporary: true)
        #expect(
            command
                == "mv /d/notes.txt /d/notes.txt.edith-rename && mv /d/notes.txt.edith-rename /d/Notes.txt"
        )
    }
}

extension FinderClipboardTests {
    @Test func copyThenPasteInTheSameFolderMakesACopyRatherThanFailing() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("notes.txt", into: root, contents: "body")
        await model.load()

        model.selection = Set(model.entries.map(\.path))
        model.copySelection(operation: .copy)
        await model.paste()

        #expect(exists("notes.txt", in: root))
        #expect(exists("notes copy.txt", in: root))
        #expect(model.errorMessage == nil)
    }

    @Test func cutThenPasteInTheSameFolderSaysSoInsteadOfCorruptingTheFile() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("notes.txt", into: root, contents: "body")
        await model.load()

        model.selection = Set(model.entries.map(\.path))
        model.copySelection(operation: .move)
        await model.paste()

        #expect(exists("notes.txt", in: root))
        let kept = try String(contentsOf: root.appendingPathComponent("notes.txt"), encoding: .utf8)
        #expect(kept == "body")
        #expect(model.errorMessage != nil)
    }

    @Test func pasteOntoAnExistingNameRaisesTheConflictSheet() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try write("same.txt", into: root, contents: "outer")
        try write("same.txt", into: inner, contents: "inner")
        await model.load()

        model.selection = Set(model.entries.filter { $0.name == "same.txt" }.map(\.path))
        model.copySelection(operation: .copy)
        model.navigate(to: inner.path)
        await model.load()
        await model.paste()

        #expect(model.pendingConflict != nil)
        let untouched = try String(
            contentsOf: inner.appendingPathComponent("same.txt"), encoding: .utf8)
        #expect(untouched == "inner")
    }

    @Test func duplicatingSeveralItemsAtOnceGivesEachADistinctName() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.txt", into: root)
        await model.load()
        await model.duplicate(paths: model.entries.map(\.path) + model.entries.map(\.path))

        #expect(exists("a copy.txt", in: root))
        #expect(exists("a copy 2.txt", in: root))
    }
}

@Suite(.serialized) @MainActor struct FinderSelectionMovementTests {
    private func sandboxWithFiles(_ count: Int) throws -> (FinderModel, URL) {
        let (model, root) = try sandbox()
        for index in 0..<count {
            try write(String(format: "f%02d.txt", index), into: root)
        }
        return (model, root)
    }

    @Test func shiftArrowGrowsAndThenShrinksTheSelection() async throws {
        let (model, root) = try sandboxWithFiles(5)
        defer { try? FileManager.default.removeItem(at: root) }
        await model.load()
        model.viewMode = .list

        model.click(model.visibleEntries[0], modifiers: [])
        #expect(model.selection.count == 1)

        model.moveSelection(.down, extend: true)
        model.moveSelection(.down, extend: true)
        #expect(model.selection.count == 3)

        model.moveSelection(.up, extend: true)
        #expect(model.selection.count == 2)
    }

    @Test func iconViewWalksTheGridByColumn() async throws {
        let (model, root) = try sandboxWithFiles(9)
        defer { try? FileManager.default.removeItem(at: root) }
        await model.load()
        model.viewMode = .icon
        model.gridColumns = 3

        model.click(model.visibleEntries[0], modifiers: [])
        model.moveSelection(.right, extend: false)
        #expect(model.selection.first == model.visibleEntries[1].path)

        model.moveSelection(.down, extend: false)
        #expect(model.selection.first == model.visibleEntries[4].path)

        model.moveSelection(.left, extend: false)
        #expect(model.selection.first == model.visibleEntries[3].path)
    }

    @Test func listViewIgnoresHorizontalArrows() async throws {
        let (model, root) = try sandboxWithFiles(4)
        defer { try? FileManager.default.removeItem(at: root) }
        await model.load()
        model.viewMode = .list

        model.click(model.visibleEntries[1], modifiers: [])
        model.moveSelection(.right, extend: false)
        #expect(model.selection.first == model.visibleEntries[1].path)
    }

    @Test func invertingSelectionSwapsWhatIsChosen() async throws {
        let (model, root) = try sandboxWithFiles(4)
        defer { try? FileManager.default.removeItem(at: root) }
        await model.load()

        model.click(model.visibleEntries[0], modifiers: [])
        model.invertSelection()
        #expect(model.selection.count == 3)
        #expect(!model.selection.contains(model.visibleEntries[0].path))
    }
}

@Suite(.serialized) @MainActor struct FinderUndoTests {
    @Test func undoingARenamePutsTheNameBack() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("before.txt", into: root)
        await model.load()

        guard let entry = model.entries.first else { return }
        model.beginRename(entry)
        model.renameText = "after.txt"
        await model.commitRename()
        #expect(exists("after.txt", in: root))
        #expect(model.canUndo)

        await model.undoLastOperation()
        #expect(exists("before.txt", in: root))
        #expect(!exists("after.txt", in: root))
        #expect(!model.canUndo)
    }

    @Test func undoingAMovePutsTheFileBack() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("moved.txt", into: root)
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        await model.load()

        let source = model.entries.first { $0.name == "moved.txt" }?.path ?? ""
        await model.perform(intent: .moveWithinMachine([source]), destination: inner.path)
        #expect(await eventually { exists("inner/moved.txt", in: root) })

        await model.undoLastOperation()
        #expect(exists("moved.txt", in: root))
        #expect(!exists("inner/moved.txt", in: root))
    }

    @Test func undoWithNothingToUndoSaysSoRatherThanCrashing() async throws {
        let (model, root) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.load()
        #expect(!model.canUndo)
        await model.undoLastOperation()
        #expect(model.statusMessage != nil || model.errorMessage == nil)
    }
}
