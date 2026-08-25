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
        #expect(source.contains("if filteredEntries.isEmpty"))
        #expect(source.contains("ExtensionMarketplaceFilter.emptyState"))
        #expect(source.contains("ContentUnavailableView"))
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

    @Test func attentionMarketplaceSearchBindingAndSettingsAreReachable() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let pane = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "Edith/Features/Settings/Views/ExtensionsPane.swift"), encoding: .utf8)
        let navigation = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "Edith/Core/Navigation/MainNavigationView.swift"), encoding: .utf8)
        let helper = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "EdithHelper/Core/Application/AppServices.swift"), encoding: .utf8)

        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "attention" })
        #expect(
            ExtensionMarketplaceFilter.filter(
                entries: ExtensionRegistry.entries, query: "attention", category: .all
            ).map(\.id) == ["attention"])
        #expect(entry.defaultsKey == AppStorageKeys.Tabs.attentionEnabled)
        #expect(ExtensionDetailRoute(rawValue: entry.id) == .attention)
        #expect(pane.contains("case AppStorageKeys.Tabs.attentionEnabled: $attentionEnabled"))
        #expect(pane.contains("var attentionEnabled = false"))
        #expect(pane.contains("case .attention: AttentionRows()"))
        #expect(pane.contains("private struct AttentionRows: View"))
        #expect(navigation.contains("case .attention: attentionEnabled"))
        #expect(helper.contains("AppStorageKeys.Tabs.attentionEnabled"))
        #expect(
            helper.contains(
                "extensionEnabled: Self.extensionEnabled(AppStorageKeys.Tabs.attentionEnabled)"))
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
        #expect(source.contains("coordinator.lifecycleReport($0)"))
        #expect(source.contains("ExtensionReadinessModel"))
        #expect(source.contains("await readiness.refresh(.status).value"))
        #expect(source.contains("readiness.refresh(.verify)"))
        #expect(source.contains(".onDisappear { readiness.cancel() }"))
        #expect(!source.contains("Task { await refresh() }"))
        #expect(
            source.components(
                separatedBy:
                    "if report.state.phase != .enabled, report.state.phase != .disabled"
            ).count == 3)
        #expect(source.contains("report.state.phase.title"))
        #expect(source.contains("report.state.runtimePhase.title"))
        #expect(source.contains("ExtensionLifecycleState.loading(extensionID: entry.id)"))
        #expect(source.contains("ForEach(report.checks)"))
    }

    @Test func everyExtensionSheetShowsControlsBeforeDiagnosticDetail() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Settings/Views/ExtensionsPane.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sheetStart = try #require(source.range(of: "private struct ExtensionSettingsSheet"))
        let sheetEnd = try #require(
            source.range(
                of: "private struct ExtensionLifecycleRows",
                range: sheetStart.upperBound..<source.endIndex))
        let sheet = source[sheetStart.lowerBound..<sheetEnd.lowerBound]
        let controls = try #require(sheet.range(of: "ExtensionDetailRows(entry: entry)"))
        let readiness = try #require(sheet.range(of: "ExtensionLifecycleRows("))

        #expect(controls.lowerBound < readiness.lowerBound)
    }

    @Test func everyExtensionSheetUsesOneAccessibleHeaderSwitch() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Settings/Views/ExtensionsPane.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sheetStart = try #require(source.range(of: "private struct ExtensionSettingsSheet"))
        let sheetEnd = try #require(
            source.range(
                of: "private struct ExtensionLifecycleRows",
                range: sheetStart.upperBound..<source.endIndex))
        let sheet = String(source[sheetStart.lowerBound..<sheetEnd.lowerBound])

        #expect(sheet.contains(".navigationTitle(entry.title)"))
        #expect(sheet.contains("ToolbarItem(placement: .primaryAction)"))
        #expect(sheet.contains("Toggle(isOn: enabledBinding)"))
        #expect(sheet.contains(".labelsHidden()"))
        #expect(sheet.contains(".accessibilityLabel(\"\\(entry.title) enabled\")"))
        #expect(sheet.components(separatedBy: "Toggle(").count == 2)
        #expect(!sheet.contains("Section(\"Extension\")"))
        #expect(!sheet.contains("Toggle(\"Enabled\""))
        #expect(!sheet.contains("This extension is available throughout Edith."))
        #expect(!sheet.contains("Enable this extension to use its controls and workflows."))
        #expect(!sheet.contains(".disabled(!enabled)"))
        #expect(sheet.contains("Button(\"Set up required tools...\")"))
        #expect(sheet.contains("ToolProvisioningSheet(entry: entry)"))
    }

    @Test func everyExtensionDetailKeepsItsDisabledStateGate() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Settings/Views")
        let routes: [(id: String, view: String, binding: String, file: String)] = [
            ("attention", "AttentionRows", "enabled", "ExtensionsPane.swift"),
            ("usage", "UsageRows", "enabled", "ExtensionsPane.swift"),
            ("herdr", "HerdrRows", "enabled", "ExtensionsPane.swift"),
            ("quinjet", "QuinjetRows", "enabled", "ExtensionsPane.swift"),
            ("system", "SystemRows", "enabled", "ExtensionsPane.swift"),
            ("machines", "MachinesRows", "enabled", "MachinesRows.swift"),
            ("companion", "CompanionRows", "enabled", "ExtensionsPane.swift"),
            ("systemStats", "SystemStatsRows", "enabled", "ExtensionsPane.swift"),
            ("micMute", "MicMuteRows", "enabled", "ExtensionsPane.swift"),
            ("lidAwake", "LidAwakeRows", "enabled", "LidAwakeRows.swift"),
            ("music", "MusicRows", "enabled", "ExtensionsPane.swift"),
            ("calendar", "CalendarRows", "enabled", "ExtensionsPane.swift"),
            ("notchShelf", "NotchShelfRows", "enabled", "NotchShelfRows.swift"),
            ("clipboard", "ClipboardRows", "enabled", "ClipboardRows.swift"),
            ("focusDim", "FocusDimRows", "enabled", "FocusDimRows.swift"),
            ("presenter", "PresenterRows", "presenterEnabled", "PresenterRows.swift"),
            ("colorPicker", "ColorPickerRows", "colorPickerEnabled", "ColorPickerRows.swift"),
        ]

        #expect(Set(routes.map(\.id)) == Set(ExtensionDetailRoute.allCases.map(\.rawValue)))
        for route in routes {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(route.file), encoding: .utf8)
            let body = try Self.viewDeclaration(route.view, in: source)
            #expect(body.contains(".disabled(!\(route.binding))"), "\(route.id) lost its gate")
            #expect(
                body.contains(".opacity(\(route.binding) ? 1 : 0.5)"),
                "\(route.id) lost its disabled appearance")
        }
    }

    private static func viewDeclaration(_ name: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: "struct \(name): View"))
        let remaining = start.upperBound..<source.endIndex
        let ends = [
            source.range(of: "\nprivate struct ", range: remaining)?.lowerBound,
            source.range(of: "\nstruct ", range: remaining)?.lowerBound,
        ].compactMap { $0 }
        let end = ends.min() ?? source.endIndex
        return source[start.lowerBound..<end]
    }

    @Test func recoveryControlsUseTheSameOperationsAsTheCLI() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let pane = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "Edith/Features/Settings/Views/ExtensionsPane.swift"), encoding: .utf8)
        let machines = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "Edith/Features/Settings/Views/MachinesRows.swift"), encoding: .utf8)
        let model = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "Edith/Features/Machines/ViewModels/MachinesModel.swift"), encoding: .utf8)

        #expect(pane.contains("Button(\"Choose folder...\")"))
        #expect(pane.contains("MusicFolderSelectionOperationExecution.select(url.path)"))
        #expect(pane.contains("Button(\"Check sessions\")"))
        #expect(pane.contains("HerdrSessionOperationExecution.list()"))
        #expect(pane.contains("Button(\"Open setup guide\")"))
        #expect(machines.contains("Button(\"Add machine...\")"))
        #expect(machines.contains("model.add(machine, secrets: changes(secrets))"))
        #expect(model.contains("MachineMutationOperationExecution.perform("))
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
