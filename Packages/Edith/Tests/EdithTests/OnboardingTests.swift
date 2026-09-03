import Foundation
import Testing

@testable import EdithKit

@Suite struct OnboardingTests {
    @Test func noExtensionsArePreselected() {
        #expect(OnboardingFlow.initialSelectedIDs.isEmpty)
    }

    @Test func enabledExtensionIDsComeFromBackupSettings() {
        let entries = ExtensionRegistry.entries
        let enabled = entries[0]
        let disabled = entries[1]
        let settings: [String: Any] = [
            enabled.defaultsKey: true,
            disabled.defaultsKey: false,
            "unrelatedKey": true,
        ]

        let ids = OnboardingFlow.enabledExtensionIDs(settings: settings, entries: entries)

        #expect(ids == [enabled.id])
    }

    @Test func onboardingSeparatesCoreAndOptionalWorkflowTools() {
        #expect(OnboardingFlow.requiredTools(selectedIDs: ["music"]).isEmpty)
        #expect(OnboardingFlow.optionalTools(selectedIDs: ["music"]).isEmpty)
        #expect(
            OnboardingFlow.requiredTools(selectedIDs: ["downloads"]) == [.youtubeDownloader])
        #expect(
            OnboardingFlow.optionalTools(selectedIDs: ["appMaintenance"]) == [.homebrew])
        #expect(
            OnboardingFlow.requiredTools(selectedIDs: ["usage", "quinjet"])
                == [.claudeCode, .codex, .quinjet])
    }

    @Test func freshInstallShowsOnboarding() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let freshInstall = ExtensionDefaultsMigration.migrate(defaults: defaults)

        #expect(freshInstall)
        #expect(defaults.bool(forKey: ExtensionDefaultsMigration.freshInstallKey))
        #expect(OnboardingFlow.shouldShowOnboarding(defaults: defaults))
        #expect(!defaults.bool(forKey: OnboardingFlow.completionKey))
    }

    @Test func priorInstallSkipsOnboarding() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "hasPromptedPermissions")

        let freshInstall = ExtensionDefaultsMigration.migrate(defaults: defaults)

        #expect(!freshInstall)
        #expect(!defaults.bool(forKey: ExtensionDefaultsMigration.freshInstallKey))
        #expect(defaults.bool(forKey: OnboardingFlow.completionKey))
        #expect(!OnboardingFlow.shouldShowOnboarding(defaults: defaults))
    }

    @Test func existingMigrationMarkerSkipsNewTour() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: ExtensionDefaultsMigration.markerKey)

        let freshInstall = ExtensionDefaultsMigration.migrate(defaults: defaults)

        #expect(!freshInstall)
        #expect(defaults.bool(forKey: OnboardingFlow.completionKey))
        #expect(!OnboardingFlow.shouldShowOnboarding(defaults: defaults))
    }

    @Test func explicitExtensionToggleSkipsOnboarding() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "clipboardEnabled")

        ExtensionDefaultsMigration.migrate(defaults: defaults)

        #expect(defaults.bool(forKey: OnboardingFlow.completionKey))
        #expect(!OnboardingFlow.shouldShowOnboarding(defaults: defaults))
    }

    @Test func permissionStepAggregatesOnlyMissingRequiredValues() {
        let selectedIDs: Set<String> = [
            "calendar", "presenter", "colorPicker", "system", "clipboard", "usage",
        ]
        let permissions = OnboardingFlow.missingPermissions(
            selectedIDs: selectedIDs,
            granted: [
                .calendar: true,
                .screenRecording: false,
                .accessibility: false,
                .inputMonitoring: false,
                .notifications: false,
            ])

        #expect(
            permissions
                == [OnboardingPermission(permission: .screenRecording, required: true)])
        #expect(OnboardingFlow.hasOptionalPermissions(selectedIDs: selectedIDs))
    }

    @Test func optionalOnlySelectionsSkipPermissionStep() {
        let selectedIDs: Set<String> = ["system", "clipboard", "usage", "notchShelf"]

        #expect(
            OnboardingFlow.missingPermissions(selectedIDs: selectedIDs, granted: [:]).isEmpty)
        #expect(OnboardingFlow.hasOptionalPermissions(selectedIDs: selectedIDs))
    }

    @Test func preexistingPermissionIsNotNewlyGranted() {
        let count = OnboardingFlow.newlyGrantedCount(
            selectedIDs: ["usage"],
            baseline: [.notifications: true],
            current: [.notifications: true])

        #expect(count == 0)
    }

    @Test func permissionGrantedDuringOnboardingIsNewlyGranted() {
        let count = OnboardingFlow.newlyGrantedCount(
            selectedIDs: ["usage"],
            baseline: [.notifications: false],
            current: [.notifications: true])

        #expect(count == 1)
    }

    @Test func unselectedExtensionPermissionIsNotNewlyGranted() {
        let count = OnboardingFlow.newlyGrantedCount(
            selectedIDs: ["usage"],
            baseline: [.screenRecording: false],
            current: [.screenRecording: true])

        #expect(count == 0)
    }

    @Test func skipEnablesNothingButKeepsBackupsOn() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        OnboardingFlow.skip(defaults: defaults)

        #expect(defaults.bool(forKey: OnboardingFlow.completionKey))
        #expect(defaults.bool(forKey: OnboardingFlow.iCloudBackupKey))
        for entry in ExtensionRegistry.entries {
            #expect(defaults.object(forKey: entry.defaultsKey) as? Bool == false)
            #expect(defaults.object(forKey: OnboardingFlow.seenKey(for: entry)) == nil)
        }
    }

    @Test func finishWritesExactlySelectedExtensionKeys() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selectedIDs: Set<String> = ["usage", "notchShelf"]

        OnboardingFlow.finish(selectedIDs: selectedIDs, defaults: defaults)

        #expect(defaults.bool(forKey: OnboardingFlow.completionKey))
        #expect(OnboardingFlow.initialICloudBackup)
        #expect(defaults.object(forKey: OnboardingFlow.iCloudBackupKey) as? Bool == true)
        for entry in ExtensionRegistry.entries {
            if selectedIDs.contains(entry.id) {
                #expect(defaults.object(forKey: entry.defaultsKey) as? Bool == true)
                #expect(
                    defaults.object(forKey: OnboardingFlow.seenKey(for: entry)) as? Bool == true)
            } else {
                #expect(defaults.object(forKey: entry.defaultsKey) as? Bool == false)
                #expect(defaults.object(forKey: OnboardingFlow.seenKey(for: entry)) == nil)
            }
        }
    }

    @Test func unselectedAttentionStaysDisabledAcrossEveryConsumer() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let attention = try #require(ExtensionRegistry.entries.first { $0.id == "attention" })

        OnboardingFlow.finish(selectedIDs: ["usage"], defaults: defaults)

        #expect(defaults.object(forKey: attention.defaultsKey) as? Bool == false)
        #expect(!attention.isEnabled(in: defaults))
        #expect(ConfigCatalog.definition(for: attention.defaultsKey)?.fallback == .bool(false))
    }

    @Test func finishWritesICloudOptIn() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        OnboardingFlow.finish(selectedIDs: [], icloudBackup: true, defaults: defaults)

        #expect(defaults.object(forKey: OnboardingFlow.iCloudBackupKey) as? Bool == true)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "OnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

@Suite struct OnboardingSuiteSelectionTests {
    @Test func everySuiteIsOfferedWithItsAbilities() {
        let picks = OnboardingFlow.suitePicks()
        #expect(picks.map(\.id) == SuiteID.allCases)
        for pick in picks {
            #expect(!pick.abilities.isEmpty)
            #expect(pick.abilities.allSatisfy { $0.suite == pick.id })
        }
    }

    @Test func theDeveloperPresetPicksAgentsMaintenanceAndSystem() {
        #expect(OnboardingPreset.developer.suites == [.agents, .maintenance, .system])
        let ids = OnboardingFlow.abilityIDs(forSuites: Set(OnboardingPreset.developer.suites))
        #expect(ids.contains("usage"))
        #expect(ids.contains("homebrew"))
        #expect(ids.contains("micMute"))
        #expect(!ids.contains("clipboard"))
    }

    @Test func skippingLeavesCoreOnly() {
        #expect(OnboardingPreset.nothing.suites.isEmpty)
        #expect(OnboardingFlow.abilityIDs(forSuites: []).isEmpty)
    }

    @Test func abilitiesAndSuitesRoundTrip() {
        let suites: Set<SuiteID> = [.media, .data]
        let ids = OnboardingFlow.abilityIDs(forSuites: suites)
        #expect(OnboardingFlow.suites(forAbilities: ids) == suites)
    }

    @Test func permissionsAreGroupedBySuiteAndOnlyListWhatIsMissing() {
        let granted: [ExtensionPermission: Bool] = [.screenRecording: true]
        let selected = OnboardingFlow.abilityIDs(forSuites: [.desk, .media])

        let groups = OnboardingFlow.permissionsBySuite(
            selectedIDs: selected, granted: granted)
        let bySuite = Dictionary(
            uniqueKeysWithValues: groups.map { ($0.suite.id, $0.permissions) })

        #expect(bySuite[.desk]?.contains { $0.permission == .inputMonitoring } == true)
        #expect(bySuite[.desk]?.contains { $0.permission == .screenRecording } == false)
        #expect(bySuite[.media]?.contains { $0.permission == .calendar } == true)
        #expect(bySuite[.agents] == nil)
    }

    @Test func requiredPermissionsAreMarkedApartFromOptionalOnes() {
        let groups = OnboardingFlow.permissionsBySuite(
            selectedIDs: ["calendar", "notchShelf"], granted: [:])
        let media = groups.first { $0.suite.id == .media }?.permissions ?? []

        #expect(media.first { $0.permission == .calendar }?.required == true)
        #expect(media.first { $0.permission == .camera }?.required == false)
    }
}

@Suite struct MCPRegistrationTests {
    @Test func theEntryRunsEdithsOwnMCPServer() {
        let entry = MCPRegistration.entry(commandPath: "/usr/local/bin/ed")
        #expect(entry.name == "edith")
        #expect(entry.command == "/usr/local/bin/ed")
        #expect(entry.arguments == ["database", "mcp"])
    }

    @Test func registeringMergesRatherThanReplacingOtherServers() {
        let existing: [String: Any] = [
            "mcpServers": ["other": ["command": "/bin/other"]],
            "unrelated": true,
        ]
        let merged = MCPRegistration.merged(
            into: existing, entry: MCPRegistration.entry(commandPath: "/bin/ed"))
        let servers = merged["mcpServers"] as? [String: Any]

        #expect(servers?.keys.sorted() == ["edith", "other"])
        #expect(merged["unrelated"] as? Bool == true)
        #expect(MCPRegistration.isRegistered(in: merged))
    }

    @Test func anEmptyConfigurationGainsTheServersKey() {
        let merged = MCPRegistration.merged(
            into: [:], entry: MCPRegistration.entry(commandPath: "/bin/ed"))
        #expect(MCPRegistration.isRegistered(in: merged))
    }

    @Test func writingLandsOnDiskAndReadsBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")

        #expect(!MCPRegistration.isRegistered(url: url))
        #expect(
            MCPRegistration.register(url: url, entry: MCPRegistration.entry(commandPath: "/bin/ed"))
        )
        #expect(MCPRegistration.isRegistered(url: url))
    }

    @Test func theCodexLineNamesTheServerAndItsArguments() {
        let line = MCPRegistration.entry(commandPath: "/bin/ed").codexLine
        #expect(line.contains("[mcp_servers.edith]"))
        #expect(line.contains("command = \"/bin/ed\""))
        #expect(line.contains("\"database\", \"mcp\""))
    }
}
