import Foundation
import Security
import Testing
@testable import DatabaseCore

@Suite struct DatabaseStorageIdentityTests {
    @Test func originalMetadataWinsWithoutModifyingEitherExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("metadata.sqlite3")
        let extracted = root.appendingPathComponent("metadata.sqlite")
        let first = Data("synthetic-original-records".utf8)
        let second = Data("synthetic-extracted-records".utf8)
        try first.write(to: original)
        try second.write(to: extracted)
        let selected = DatabaseStorageIdentity.metadataFile(
            root: root, applicationIdentifier: "com.pulkit.edith")
        #expect(selected == original)
        #expect(try Data(contentsOf: selected) == first)
        #expect(try Data(contentsOf: extracted) == second)
        #expect(
            DatabaseStorageIdentity.metadataFile(
                root: root, applicationIdentifier: "com.pulkit.edith.dev.fixture") == extracted)
        #expect(
            DatabaseStorageIdentity.metadataFile(root: root, applicationIdentifier: nil)
                == extracted)
    }
}
