import Foundation
import Testing

struct MusicThemeSourceTests {
    @Test func extensionSourcesNeverReachForSystemAccentOrLinkColors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UI")
        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("accentColor"), "\(file.lastPathComponent)")
            #expect(!source.contains("controlAccentColor"), "\(file.lastPathComponent)")
            #expect(!source.contains(".buttonStyle(.link)"), "\(file.lastPathComponent)")
        }
    }
}
