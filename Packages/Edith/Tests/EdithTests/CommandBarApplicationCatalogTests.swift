import Foundation
import Testing

@testable import EdithHelper

@Suite struct CommandBarApplicationCatalogTests {
    @Test func loadsSortsAndDeduplicatesApplicationBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApplication(
            named: "Zulu", bundleIdentifier: "com.example.shared", under: root)
        try makeApplication(
            named: "Alpha", bundleIdentifier: "com.example.alpha", under: root)
        try makeApplication(
            named: "Zulu Copy", bundleIdentifier: "com.example.shared", under: root)

        let applications = CommandBarApplicationCatalog.load(roots: [root])

        #expect(applications.count == 2)
        #expect(applications.first?.title == "Alpha")
        #expect(applications.last?.title.hasPrefix("Zulu") == true)
        #expect(Set(applications.compactMap(\.bundleIdentifier)).count == 2)
    }

    private func makeApplication(
        named name: String, bundleIdentifier: String, under root: URL
    ) throws {
        let contents = root.appendingPathComponent("\(name).app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
