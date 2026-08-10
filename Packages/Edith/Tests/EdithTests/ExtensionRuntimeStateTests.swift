import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite struct ExtensionRuntimeStateTests {
    static let allowedWriters: Set<String> = [
        "SettingsBackup.swift", "OnboardingFlow.swift", "ExtensionDefaultsMigration.swift",
        "AppServices.swift", "OnboardingView.swift", "ExtensionsPane.swift",
    ]

    static func runtimeSources() -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var sources: [(String, String)] = []
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                !allowedWriters.contains(url.lastPathComponent),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            sources.append((url.lastPathComponent, text))
        }
        return sources
    }

    @Test func turningAFeatureOffNeverUninstallsItsExtension() throws {
        let sources = Self.runtimeSources()
        for entry in ExtensionRegistry.entries {
            let pattern = #"set\([^\n]*forKey:\s*"\#(entry.defaultsKey)"\)"#
            let regex = try NSRegularExpression(pattern: pattern)
            for source in sources {
                let range = NSRange(source.text.startIndex..., in: source.text)
                #expect(
                    regex.firstMatch(in: source.text, range: range) == nil,
                    """
                    \(source.name) writes \(entry.defaultsKey), the marketplace switch for \
                    \(entry.title). Runtime on/off belongs in a separate state key, otherwise \
                    turning the feature off uninstalls the extension and unregisters its shortcut.
                    """)
            }
        }
    }

    @Test func focusDimSeparatesInstalledFromActive() {
        #expect(FocusDimState.enabledKey != FocusDimState.activeKey)
        let defaults = UserDefaults(suiteName: "test.focusdim")!
        defaults.removePersistentDomain(forName: "test.focusdim")
        defer { defaults.removePersistentDomain(forName: "test.focusdim") }

        defaults.set(true, forKey: FocusDimState.enabledKey)
        #expect(FocusDimState.isEnabled(defaults))
        #expect(!FocusDimState.isActive(defaults))

        FocusDimState.setActive(true, defaults)
        #expect(FocusDimState.isActive(defaults))
        #expect(FocusDimState.isEnabled(defaults))

        FocusDimState.setActive(false, defaults)
        #expect(!FocusDimState.isActive(defaults))
        #expect(FocusDimState.isEnabled(defaults), "turning dimming off must keep it installed")
    }

    @Test func inactiveFocusDimIsNotReportedActiveWhenExtensionIsOff() {
        let defaults = UserDefaults(suiteName: "test.focusdim.off")!
        defaults.removePersistentDomain(forName: "test.focusdim.off")
        defer { defaults.removePersistentDomain(forName: "test.focusdim.off") }

        defaults.set(true, forKey: FocusDimState.activeKey)
        #expect(!FocusDimState.isActive(defaults))
    }
}
