@testable import MachinesExtension
import Foundation
import Testing

@Suite struct MachinePackagingTests {
    @Test func nativeManifestPackagesEveryOwnedSourceAndResourceWithoutHostPayload() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifestURL = root.appendingPathComponent("Extensions/manifest.json")
        let definitions = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [[String: Any]])
        let manifest = try #require(definitions.first { $0["id"] as? String == "machines" })
        #expect(manifest["testTargets"] as? [String] == ["ci-extension-machines"])
        #expect(manifest["contractVersion"] as? Int == 1)
        #expect(manifest["surfaceContractVersion"] as? Int == 1)
        #expect(manifest["usesHostFramework"] == nil)
        #expect(manifest["nativePackage"] as? String == "Extensions/terminal/Native")
        #expect(manifest["nativeProduct"] as? String == "GhosttyTerminal")
        let roles = try #require(manifest["roles"] as? [String: [String]])
        let packaged = Set(roles.values.flatMap { $0 })
        let directory = root.appendingPathComponent("Extensions/machines")
        let enumerator = try #require(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var owned: Set<String> = []
        for case let url as URL in enumerator {
            if ["Tests", ".build", ".swiftpm"].contains(url.lastPathComponent) {
                enumerator.skipDescendants(); continue
            }
            guard url.pathExtension == "swift", url.lastPathComponent != "Package.swift" else {
                continue
            }
            owned.insert(String(url.path.dropFirst(root.path.count + 1)))
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(!source.contains("import EdithKit"))
            #expect(!source.contains("import Edith\n"))
            #expect(!source.unicodeScalars.contains { $0.value == 0x2014 })
        }
        #expect(owned == packaged)
        let resources = try #require(manifest["resources"] as? [String: [String]])
        #expect(
            Set(resources.values.flatMap { $0 }) == [
                "Extensions/machines/Resources/machine-collector.sh",
                "Extensions/machines/Resources/windows-machine-collector.ps1",
                "Extensions/machines/Resources/usage-snapshot.py",
            ])
        let centralPackage = try String(
            contentsOf: root.appendingPathComponent("Extensions/Package.swift"), encoding: .utf8)
        #expect(!centralPackage.contains("GhosttyTerminal"))
    }
}
