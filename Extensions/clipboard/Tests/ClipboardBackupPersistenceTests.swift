import Foundation
import Testing
@testable import ClipboardExtension

@Suite struct ClipboardBackupPersistenceTests {
    @Test func backupUsesThePreservedProductionSourceAndKeepsFixturesIsolated() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let original = support.appendingPathComponent("Edith/clipboard")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let file = original.appendingPathComponent("synthetic.json")
        let bytes = Data("preserved backup source".utf8)
        try bytes.write(to: file)
        let root = support.appendingPathComponent("Edith/Data/clipboard")
        var environment = [
            "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith",
            "EDITH_EXTENSION_ID": "clipboard", "EDITH_EXTENSION_DATA_ROOT": root.path,
        ]
        let selected = ClipboardBackupProvider.localDirectory(environment: environment, root: root)
        #expect(selected.path == original.path)
        #expect(try Data(contentsOf: selected.appendingPathComponent("synthetic.json")) == bytes)
        environment["EDITH_APPLICATION_IDENTIFIER"] = "com.pulkit.edith.tests.synthetic"
        #expect(
            ClipboardBackupProvider.localDirectory(environment: environment, root: root).path
                == root.appendingPathComponent("clipboard").path)
    }
}
