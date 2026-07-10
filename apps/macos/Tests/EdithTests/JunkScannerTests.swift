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

    @Test func directorySizeSumsRegularFiles() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let data = Data(repeating: 0, count: 4096)
        try data.write(to: home.appendingPathComponent("a.bin"))
        try data.write(to: home.appendingPathComponent("b.bin"))
        let size = JunkScanner.directorySize(home)
        #expect(size >= 8192)
    }

    @Test func scanFindsExistingCategoriesOnly() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let derived = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(to: derived.appendingPathComponent("x.o"))

        let categories = JunkScanner.scan(home: home)
        #expect(categories.contains { $0.id == "derivedData" })
        #expect(!categories.contains { $0.id == "npm" })
    }

    @Test func emptyHomeYieldsNothing() {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(JunkScanner.scan(home: home).isEmpty)
    }

    @Test func formatIsHumanReadable() {
        #expect(JunkScanner.format(0) == "Zero KB" || JunkScanner.format(0) == "Zero bytes")
        #expect(JunkScanner.format(1_500_000).contains("MB"))
    }
}
