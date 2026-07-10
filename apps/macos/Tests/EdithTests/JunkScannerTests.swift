import Foundation
import Testing

@testable import Edith

@Suite struct JunkScannerTests {
    private func tempHome() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-junk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var derivedEntry: JunkCatalog.Entry {
        JunkCatalog.entries.first { $0.id == "derivedData" }!
    }

    @Test func directorySizeSumsRegularFiles() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let data = Data(repeating: 0, count: 4096)
        try data.write(to: home.appendingPathComponent("a.bin"))
        try data.write(to: home.appendingPathComponent("b.bin"))
        #expect(JunkScanner.directorySize(home) >= 8192)
    }

    @Test func scanCategoryListsChildrenAsItems() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let derived = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        try FileManager.default.createDirectory(
            at: derived.appendingPathComponent("ProjA"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: derived.appendingPathComponent("ProjB"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(
            to: derived.appendingPathComponent("ProjA/build.o"))
        try Data(repeating: 1, count: 9000).write(
            to: derived.appendingPathComponent("ProjB/build.o"))

        let category = JunkScanner.scanCategory(derivedEntry, home: home)
        #expect(category?.items.count == 2)
        #expect(category?.items.first?.name == "ProjB")
    }

    @Test func absentCategoryReturnsNil() {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(JunkScanner.scanCategory(derivedEntry, home: home) == nil)
    }

    @Test func categorySelectionReflectsItems() {
        var category = JunkCategory(
            id: "x", name: "X", detail: "",
            items: [
                JunkItem(
                    id: "a", name: "a", path: URL(fileURLWithPath: "/a"), sizeBytes: 1,
                    selected: true),
                JunkItem(
                    id: "b", name: "b", path: URL(fileURLWithPath: "/b"), sizeBytes: 1,
                    selected: false),
            ])
        #expect(category.selection == .some)
        category.items[1].selected = true
        #expect(category.selection == .all)
        #expect(category.selectedBytes == 2)
    }

    @Test func drivesIncludeTheBootVolume() {
        let drives = JunkScanner.drives()
        #expect(!drives.isEmpty)
        #expect(drives.contains { !$0.isExternal && $0.totalBytes > 0 })
    }

    @Test func formatIsHumanReadable() {
        #expect(JunkScanner.format(1_500_000).contains("MB"))
    }
}
