import Foundation
import Testing
@testable import EdithHelper

@Suite struct SettingsBackupTests {
    @Test func everyAppStoragePreferenceIsBackedUpOrDeviceLocal() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        let regex = try NSRegularExpression(pattern: #"@AppStorage\("([^"]+)""#)
        var keys = Set<String>()
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                let source = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(String(source[keyRange]))
            }
        }
        let covered = Set(SettingsBackup.backedKeys).union(SettingsBackup.deviceLocalKeys)
        #expect(keys.subtracting(covered).isEmpty)
        #expect(
            keys.intersection(SettingsBackup.backedKeys).isSubset(of: SettingsBackup.sharedKeys))
    }

    @Test func configurableNonAppStoragePreferencesAreBackedUp() {
        let expected: Set<String> = [
            "micHotKeyCode", "micHotKeyMods", "micHotKeyLabel", "notchAudioMixerEnabled",
        ]
        #expect(expected.isSubset(of: Set(SettingsBackup.backedKeys)))
        #expect(expected.isSubset(of: SettingsBackup.sharedKeys))
    }
}
