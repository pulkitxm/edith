import EdithKit
import Foundation
import Testing

@testable import Edith

@MainActor
@Suite struct QuinjetFolderPickerTests {
    @Test func loadsHomeAndSortsDirectoriesBeforeFiles() async {
        let model = makeModel()

        await model.start()

        #expect(model.path == "/home/pulkit")
        #expect(model.directory == "/home/pulkit")
        #expect(model.entries.map(\.name) == ["Desktop", "notes.txt"])
    }

    @Test func filtersRealtimeInputAndCompletesWithTab() async {
        let model = makeModel()
        await model.start()

        model.editPath("/home/pulkit/Desk")
        try? await Task.sleep(for: .milliseconds(5))

        #expect(model.entries.map(\.name) == ["Desktop"])
        await model.completePath()
        #expect(model.path == "/home/pulkit/Desktop")
        #expect(model.directory == "/home/pulkit/Desktop")
        #expect(model.entries.map(\.name) == ["edith", "quinjet"])
    }

    @Test func arrowsActivateDirectoriesAndCurrentFolder() async {
        let model = makeModel()
        await model.start()

        #expect(await model.activateSelection() == "/home/pulkit")
        model.moveSelection(by: 1)
        #expect(model.selectedEntry?.name == "Desktop")
        #expect(await model.activateSelection() == nil)
        #expect(model.directory == "/home/pulkit/Desktop")
    }

    @Test func commandUndoReturnsToPreviousDirectory() async {
        let model = makeModel()
        await model.start()
        await model.navigate(to: "/home/pulkit/Desktop")

        await model.undoNavigation()

        #expect(model.directory == "/home/pulkit")
        #expect(!model.canUndo)
    }

    private func makeModel() -> QuinjetFolderPickerModel {
        let directories = [
            "/home/pulkit": [
                entry("notes.txt", parent: "/home/pulkit", kind: .file),
                entry("Desktop", parent: "/home/pulkit", kind: .directory),
            ],
            "/home/pulkit/Desktop": [
                entry("quinjet", parent: "/home/pulkit/Desktop", kind: .directory),
                entry("edith", parent: "/home/pulkit/Desktop", kind: .directory),
            ],
        ]
        return QuinjetFolderPickerModel(
            debounce: .zero,
            resolveHome: { "/home/pulkit" },
            listDirectory: { directories[$0] ?? [] })
    }

    private func entry(
        _ name: String, parent: String, kind: FileEntryKind
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name, path: FileListing.join(parent: parent, name: name), kind: kind,
            sizeBytes: 0)
    }
}
