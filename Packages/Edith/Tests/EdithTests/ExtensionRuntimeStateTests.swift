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

    @Test func extensionsScreenUsesOneStableCardOrder() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Settings/Views/ExtensionsPane.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("ForEach(filteredEntries)"))
        #expect(!source.contains("enabledEntries"))
        #expect(!source.contains("availableEntries"))
    }

    @Test func quinjetMarketplaceBindingAndSettingsAreReachable() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Settings/Views/ExtensionsPane.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("var quinjetEnabled = false"))
        #expect(source.contains("case AppStorageKeys.Tabs.quinjetEnabled: $quinjetEnabled"))
        #expect(source.contains("case .quinjet: QuinjetRows()"))
        #expect(source.contains("private struct QuinjetRows: View"))
        #expect(source.contains("CLIToolStatusSection(tools: [.quinjet]"))
        #expect(!source.contains("guard entry.id != \"calendar\""))
    }

    @Test func everyExtensionSettingsSheetHasLifecycleContent() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Settings/Views/ExtensionsPane.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("ExtensionLifecycleRows("))
        #expect(source.contains("if let lifecycle = entry.lifecycle"))
        #expect(source.contains("Text(entry.subtitle)"))
        #expect(source.contains("coordinator.lifecycleReport()"))
        #expect(source.contains("report.state.phase.title"))
        #expect(source.contains("report.state.runtimePhase.title"))
        #expect(source.contains("ExtensionLifecycleState.loading(extensionID: entry.id)"))
        #expect(source.contains("ForEach(report.checks)"))
    }

    @Test func everyExtensionMutationSurfaceUsesTheSharedCenter() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let app = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "Edith/Features/Settings/Views/ExtensionsPane.swift"), encoding: .utf8)
        let onboarding = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "EdithKit/Features/Onboarding/Models/OnboardingFlow.swift"), encoding: .utf8)
        let commands = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "EdithCLI/Commands/ExtensionCommands.swift"), encoding: .utf8)
        let tools = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "EdithCLI/Commands/ToolsCommands.swift"), encoding: .utf8)

        #expect(app.contains("ExtensionMutationCenter.application"))
        #expect(!app.contains("enabled.wrappedValue ="))
        #expect(onboarding.contains("ExtensionMutationCenter(environment:"))
        #expect(commands.contains("mutationCenter().setEnabled"))
        #expect(commands.contains("mutationCenter().setup"))
        #expect(tools.contains("mutationCenter().install"))
    }

    @Test func homeQuickActionsUseFourColumnsAndIncludeLidAwake() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Pages/Views/HomePageView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("count: 4"))
        #expect(source.contains("title: \"Lid awake\""))
        #expect(source.contains("IPC.post(IPC.Name.toggleLidAwake)"))
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
