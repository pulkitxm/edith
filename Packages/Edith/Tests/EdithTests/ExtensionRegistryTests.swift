import Foundation
import Testing

@testable import Edith
@testable import EdithCore
@testable import EdithKit

@Suite struct ExtensionRegistryTests {
    private let knownDefaultsKeys: Set<String> = [
        "tabUsageEnabled",
        "tabHerdrEnabled",
        "tabQuinjetEnabled",
        "tabCompanionEnabled",
        "appMaintenanceEnabled",
        "homebrewEnabled",
        "cleanerEnabled",
        "tabSystemEnabled",
        "lidAwakeEnabled",
        "menuBarSystemStats",
        "micMuteEnabled",
        "clipboardEnabled",
        "emojiEnabled",
        "colorPickerEnabled",
        "keystrokeHighlightEnabled",
        "focusDimEnabled",
        "presenterEnabled",
        "tabMusicEnabled",
        "downloadsEnabled",
        "notchShelfEnabled",
        "notchAudioMixerEnabled",
        "tabCalendarEnabled",
        "tabDatabaseEnabled",
        "tabAttentionEnabled",
        "tabSEOAuditEnabled",
    ]

    @Test func registryIdentifiersAreUnique() {
        let identifiers = ExtensionRegistry.entries.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test func registryMatchesCurrentBaseline() {
        #expect(
            ExtensionRegistry.entries.map(\.id) == [
                "usage", "herdr", "quinjet", "companion",
                "appMaintenance", "homebrew", "cleaner",
                "system", "lidAwake", "systemStats", "micMute",
                "clipboard", "emoji", "colorPicker", "keystrokeHighlight", "focusDim", "presenter",
                "music", "downloads", "notchShelf", "audioMixer", "calendar",
                "database", "attention", "seoAudit",
            ])
    }

    @Test func everyAbilityBelongsToOneSuiteAndOneHost() {
        for suite in SuiteRegistry.suites {
            #expect(!SuiteRegistry.abilities(in: suite.id).isEmpty)
        }
        let grouped = ExtensionRegistry.entries.flatMap { entry in
            SuiteRegistry.abilities(in: entry.suite).map(\.id)
        }
        #expect(Set(grouped) == Set(ExtensionRegistry.entries.map(\.id)))
        #expect(ExtensionRegistry.entries.allSatisfy { AbilityHost.allCases.contains($0.host) })
    }

    @Test func suiteDefaultsKeysAreUniqueAndDistinctFromAbilities() {
        let suiteKeys = SuiteRegistry.defaultsKeys
        #expect(Set(suiteKeys).count == suiteKeys.count)
        #expect(Set(suiteKeys).isDisjoint(with: knownDefaultsKeys))
        for key in suiteKeys {
            #expect(ConfigCatalog.definition(for: key)?.fallback == .bool(false))
        }
    }

    @Test func abilityRequirementsPointAtRegisteredAbilities() {
        let identifiers = Set(ExtensionRegistry.entries.map(\.id))
        for entry in ExtensionRegistry.entries {
            for requirement in entry.requires {
                #expect(identifiers.contains(requirement))
                #expect(requirement != entry.id)
            }
        }
        #expect(ExtensionRegistry.entry("quinjet")?.requires == ["herdr"])
        #expect(ExtensionRegistry.entry("audioMixer")?.requires == ["notchShelf"])
        #expect(ExtensionRegistry.entry("downloads")?.requires == ["music"])
        #expect(ExtensionRegistry.entry("homebrew")?.requires == ["appMaintenance"])
    }

    @Test func fleetIsCoreAndNoLongerAnAbility() {
        #expect(ExtensionRegistry.entry("machines") == nil)
        #expect(!knownDefaultsKeys.contains("tabMachinesEnabled"))
    }

    @Test func lifecycleCatalogCoversEveryRegistryEntry() throws {
        let identifiers = ExtensionRegistry.entries.map(\.id)
        #expect(ExtensionLifecycleCatalog.descriptors.map(\.id) == identifiers)

        for entry in ExtensionRegistry.entries {
            let lifecycle = try #require(entry.lifecycle)
            #expect(lifecycle.id == entry.id)
            #expect(!lifecycle.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!lifecycle.workflows.isEmpty)
            #expect(!lifecycle.prerequisites.isEmpty)
            #expect(!lifecycle.cliExamples.isEmpty)
            #expect(!lifecycle.documentation.isEmpty)
            #expect(!lifecycle.recovery.isEmpty)
            #expect(!lifecycle.verification.isEmpty)
            #expect(lifecycle.recovery.allSatisfy { $0.command?.isEmpty == false })
            #expect(lifecycle.verification.allSatisfy { $0.command?.isEmpty == false })
        }
    }

    @Test func lifecycleDocumentationTargetsExist() {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for descriptor in ExtensionLifecycleCatalog.allDescriptors {
            for document in descriptor.documentation {
                let target = repository.appendingPathComponent(document.path)
                #expect(
                    FileManager.default.fileExists(atPath: target.path),
                    "\(descriptor.id) documentation is missing at \(document.path)")
            }
        }
    }

    @Test func registryDefaultsKeysAreUniqueAndComplete() {
        let defaultsKeys = ExtensionRegistry.entries.map(\.defaultsKey)
        #expect(Set(defaultsKeys).count == defaultsKeys.count)
        #expect(Set(defaultsKeys) == knownDefaultsKeys)
    }

    @Test func dynamicEnablementStorageWritesASyntheticDefaultsKey() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "syntheticExtensionEnabled"
        let storage = ExtensionEnablementStorage(defaultsKey: key, store: defaults)

        #expect(defaults.object(forKey: key) == nil)
        #expect(!storage.wrappedValue)
        storage.projectedValue.wrappedValue = true
        #expect(defaults.object(forKey: key) as? Bool == true)
        storage.projectedValue.wrappedValue = false
        #expect(defaults.object(forKey: key) as? Bool == false)
    }

    @Test func dynamicEnablementStorageWritesEveryCurrentRegistryKey() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for entry in ExtensionRegistry.entries {
            let storage = ExtensionEnablementStorage(entry: entry, store: defaults)
            storage.projectedValue.wrappedValue = true
            #expect(defaults.object(forKey: entry.defaultsKey) as? Bool == true)
            storage.projectedValue.wrappedValue = false
            #expect(defaults.object(forKey: entry.defaultsKey) as? Bool == false)
        }
    }

    @Test func cardAndModalStorageShareOneObservedValue() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "sharedExtensionEnabled"
        let card = ExtensionEnablementStorage(defaultsKey: key, store: defaults)
        let modal = ExtensionEnablementStorage(defaultsKey: key, store: defaults)

        card.projectedValue.wrappedValue = true
        #expect(modal.wrappedValue)
        modal.projectedValue.wrappedValue = false
        #expect(!card.wrappedValue)
    }

    @Test func cardsAndSheetsUseDynamicStorageWithoutAConstantFallback() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/Edith/Features/Settings/Views/ExtensionsPane.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("default: .constant(false)"))
        #expect(!source.contains("enabledBinding(for entry:"))
        #expect(source.contains("Toggle(\"\", isOn: enabledBinding)"))
        #expect(source.contains("setEnabled: { setEnabled($0, for: entry) }"))
        #expect(source.components(separatedBy: "coordinator.setEnabled(").count == 3)
        #expect(
            source.components(
                separatedBy: "ExtensionEnablementStorage(entry: entry)"
            ).count == 3)
        #expect(source.contains("ExtensionEnablementStorage(defaultsKey: suite.defaultsKey)"))
    }

    @Test func featuredEntriesArePresent() {
        let featuredIdentifiers = Set(
            ExtensionRegistry.entries.filter(\.featured).map(\.id))
        #expect(
            featuredIdentifiers == [
                "usage", "herdr", "quinjet", "appMaintenance", "system", "clipboard",
                "keystrokeHighlight", "notchShelf", "database", "attention",
            ])
    }

    @Test func toolRequirementsMatchExtensionDependencies() {
        let music = ExtensionRegistry.entry("music")!
        let downloads = ExtensionRegistry.entry("downloads")!
        let usage = ExtensionRegistry.entry("usage")!
        let quinjet = ExtensionRegistry.entry("quinjet")!
        let maintenance = ExtensionRegistry.entry("appMaintenance")!
        let homebrew = ExtensionRegistry.entry("homebrew")!

        #expect(music.requiredTools.isEmpty)
        #expect(music.optionalTools.isEmpty)
        #expect(downloads.requiredTools == [.youtubeDownloader])
        #expect(usage.requiredTools == [.claudeCode, .codex])
        #expect(usage.optionalTools.isEmpty)
        #expect(quinjet.requiredTools == [.quinjet])
        #expect(maintenance.requiredTools.isEmpty)
        #expect(maintenance.optionalTools == [.homebrew])
        #expect(homebrew.requiredTools == [.homebrew])
        #expect(CLIToolSpec.claudeCode.requirement == .always)
        #expect(
            CLIToolSpec.codex.requirement
                == .whenPreferenceEnabled(key: "codexLimitsEnabled", defaultValue: true))
    }

    @Test func unsetExtensionDefaultsMatchEveryEffectiveConfigurationFallback() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for entry in ExtensionRegistry.entries {
            #expect(defaults.object(forKey: entry.defaultsKey) == nil)
            #expect(!entry.isSelected(in: defaults))
            #expect(!entry.isEnabled(in: defaults))
            #expect(ConfigCatalog.definition(for: entry.defaultsKey)?.fallback == .bool(false))
        }
    }

    @Test func anAbilityNeedsItsSuiteAndItsRequirements() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let quinjet = ExtensionRegistry.entry("quinjet")!

        defaults.set(true, forKey: quinjet.defaultsKey)
        #expect(quinjet.isSelected(in: defaults))
        #expect(!quinjet.isEnabled(in: defaults))

        defaults.set(true, forKey: AppStorageKeys.Suites.agents)
        #expect(!quinjet.isEnabled(in: defaults))
        #expect(quinjet.unmetRequirements(in: defaults).map(\.id) == ["herdr"])

        defaults.set(true, forKey: AppStorageKeys.Tabs.herdrEnabled)
        #expect(quinjet.isEnabled(in: defaults))
        #expect(quinjet.unmetRequirements(in: defaults).isEmpty)
    }

    @Test func turningASuiteOffAndOnRestoresTheSameAbilities() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: AppStorageKeys.Suites.desk)
        defaults.set(true, forKey: AppStorageKeys.Clipboard.enabled)
        defaults.set(true, forKey: AppStorageKeys.Emoji.enabled)

        SuiteEnablement.setEnabled(false, suite: .desk, defaults: defaults)
        #expect(!SuiteEnablement.isEnabled(.desk, defaults: defaults))
        #expect(defaults.object(forKey: AppStorageKeys.Clipboard.enabled) as? Bool == false)

        SuiteEnablement.setEnabled(true, suite: .desk, defaults: defaults)
        #expect(SuiteEnablement.isEnabled(.desk, defaults: defaults))
        #expect(
            Set(SuiteEnablement.enabledAbilities(in: .desk, defaults: defaults).map(\.id))
                == ["clipboard", "emoji"])
    }

    @Test func marketplaceFilterMatchesQueryAndCategory() {
        let titleMatches = ExtensionMarketplaceFilter.filter(
            entries: ExtensionRegistry.entries, query: "MIXER", category: .all)
        let subtitleMatches = ExtensionMarketplaceFilter.filter(
            entries: ExtensionRegistry.entries, query: "schedule", category: .all)
        let categoryMatches = ExtensionMarketplaceFilter.filter(
            entries: ExtensionRegistry.entries, query: "", category: .desk)
        let combinedMatches = ExtensionMarketplaceFilter.filter(
            entries: ExtensionRegistry.entries, query: "screen", category: .desk)
        let attentionMatches = ExtensionMarketplaceFilter.filter(
            entries: ExtensionRegistry.entries, query: "attention", category: .all)

        #expect(titleMatches.map(\.id) == ["audioMixer"])
        #expect(subtitleMatches.map(\.id) == ["calendar"])
        #expect(categoryMatches.allSatisfy { $0.suite == .desk })
        #expect(combinedMatches.map(\.id) == ["keystrokeHighlight", "presenter"])
        #expect(attentionMatches.map(\.id) == ["attention"])
    }

    @Test func marketplaceTextSearchIgnoresAStaleCategory() {
        for category in [
            ExtensionMarketplaceCategory.agents, .system, .media,
        ] {
            let matches = ExtensionMarketplaceFilter.filter(
                entries: ExtensionRegistry.entries, query: " attention ", category: category)
            #expect(matches.map(\.id) == ["attention"])
        }
    }

    @Test func marketplaceEmptyStateExplainsSearchAndCategory() {
        let search = ExtensionMarketplaceFilter.emptyState(
            query: " missing ability ", category: .agents)
        #expect(search.title == "No abilities found")
        #expect(search.detail == "No ability matches \"missing ability\". Try another search.")

        let category = ExtensionMarketplaceFilter.emptyState(query: "", category: .desk)
        #expect(category.title == "No Desk abilities")
        #expect(category.detail == "This suite has no abilities available.")

        let marketplace = ExtensionMarketplaceFilter.emptyState(query: "  ", category: .all)
        #expect(marketplace.title == "No abilities available")
        #expect(marketplace.detail == "No abilities are registered yet.")
    }

    @Test func permissionTiersMatchFeatureRequirements() {
        let required: [String: [ExtensionPermission]] = [
            "usage": [],
            "herdr": [],
            "quinjet": [],
            "companion": [],
            "appMaintenance": [],
            "homebrew": [],
            "cleaner": [],
            "system": [],
            "lidAwake": [],
            "systemStats": [],
            "micMute": [],
            "clipboard": [],
            "emoji": [],
            "colorPicker": [.screenRecording],
            "keystrokeHighlight": [.inputMonitoring],
            "focusDim": [.screenRecording],
            "presenter": [.screenRecording],
            "music": [],
            "downloads": [],
            "notchShelf": [],
            "audioMixer": [],
            "calendar": [.calendar],
            "database": [],
            "attention": [],
            "seoAudit": [],
        ]
        let optional: [String: [ExtensionPermission]] = [
            "usage": [.notifications],
            "herdr": [],
            "quinjet": [],
            "companion": [],
            "appMaintenance": [.notifications],
            "homebrew": [],
            "cleaner": [],
            "system": [.accessibility, .inputMonitoring],
            "lidAwake": [],
            "systemStats": [],
            "micMute": [],
            "clipboard": [.accessibility],
            "emoji": [.accessibility],
            "colorPicker": [],
            "keystrokeHighlight": [],
            "focusDim": [],
            "presenter": [],
            "music": [],
            "downloads": [],
            "notchShelf": [.bluetooth, .camera, .automation],
            "audioMixer": [.applicationAudio],
            "calendar": [],
            "database": [],
            "attention": [],
            "seoAudit": [],
        ]

        let identifiers = Set(ExtensionRegistry.entries.map(\.id))
        #expect(Set(required.keys) == identifiers)
        #expect(Set(optional.keys) == identifiers)
        for entry in ExtensionRegistry.entries {
            #expect(entry.requiredPermissions == required[entry.id, default: []])
            #expect(entry.optionalPermissions == optional[entry.id, default: []])
        }
    }

    @Test func capabilityTiersDriveExtensionAvailability() {
        let clipboard = ExtensionRegistry.entry("clipboard")!
        let audioMixer = ExtensionRegistry.entry("audioMixer")!
        let macOS143 = PlatformCapabilities.macOS(
            version: OperatingSystemVersion(majorVersion: 14, minorVersion: 3, patchVersion: 0))
        let macOS144 = PlatformCapabilities.macOS(
            version: OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0))

        #expect(clipboard.availability(on: .macOS) == .available)
        #expect(
            macOS143.state(for: .applicationAudio)
                == .unsupported("Application audio mixing requires macOS 14.4 or later."))
        #expect(audioMixer.availability(on: macOS143) == .unavailable([.applicationAudio]))
        #expect(macOS144.state(for: .applicationAudio) == .permissionRequired)
        #expect(audioMixer.availability(on: macOS144) == .available)
    }

    @Test func capabilityTiersDoNotOverlap() {
        for entry in ExtensionRegistry.entries {
            #expect(!entry.requiredCapabilities.isEmpty)
            #expect(
                Set(entry.requiredCapabilities).isDisjoint(with: entry.optionalCapabilities))
        }
    }

    @Test func missingRequiredPermissionsShowSheet() {
        let entry = ExtensionRegistry.entry("presenter")!
        let decision = ExtensionPermissionFlow.decision(
            for: entry, granted: [.screenRecording: false], hasSeenPermissions: true)
        #expect(
            decision
                == .showSheet(
                    required: [.screenRecording], optional: []))
    }

    @Test func grantedRequiredPermissionsEnableDirectly() {
        let entry = ExtensionRegistry.entry("presenter")!
        let decision = ExtensionPermissionFlow.decision(
            for: entry, granted: [.screenRecording: true], hasSeenPermissions: false)
        #expect(decision == .enableDirectly)
    }

    @Test func unseenSystemPermissionsAreOptional() {
        let entry = ExtensionRegistry.entry("system")!
        let decision = ExtensionPermissionFlow.decision(
            for: entry, granted: [.accessibility: true, .inputMonitoring: false],
            hasSeenPermissions: false)
        #expect(decision == .enableDirectly)
    }

    @Test func unseenMissingOptionalPermissionsEnableDirectly() {
        let entry = ExtensionRegistry.entry("notchShelf")!
        let decision = ExtensionPermissionFlow.decision(
            for: entry, granted: [.bluetooth: false, .camera: true],
            hasSeenPermissions: false)
        #expect(decision == .enableDirectly)
    }

    @Test func seenOptionalPermissionsEnableDirectly() {
        let entry = ExtensionRegistry.entry("notchShelf")!
        let decision = ExtensionPermissionFlow.decision(
            for: entry, granted: [.bluetooth: false, .camera: false],
            hasSeenPermissions: true)
        #expect(decision == .enableDirectly)
    }

    @Test func grantedOptionalPermissionsEnableDirectlyWithoutPriorEnable() {
        let entry = ExtensionRegistry.entry("clipboard")!
        let decision = ExtensionPermissionFlow.decision(
            for: entry, granted: [.accessibility: true], hasSeenPermissions: false)
        #expect(decision == .enableDirectly)
    }

    @Test func everyPermissionReasonIsUserFacing() {
        for permission in ExtensionPermission.allCases {
            #expect(!permission.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!permission.reason.localizedCaseInsensitiveContains("helper"))
        }
    }

    @Test func freshInstallLeavesExtensionsOff() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ExtensionDefaultsMigration.migrate(defaults: defaults)

        #expect(defaults.bool(forKey: ExtensionDefaultsMigration.markerKey))
        for key in knownDefaultsKeys {
            #expect(defaults.object(forKey: key) == nil)
            #expect(!defaults.bool(forKey: key))
        }
        for key in SuiteRegistry.defaultsKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
        #expect(
            defaults.integer(forKey: ExtensionDefaultsMigration.registryVersionKey)
                == ExtensionDefaultsMigration.registryVersion)
    }

    @Test func priorInstallPreservesEffectiveLegacyValues() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "hasPromptedPermissions")
        defaults.set(false, forKey: "tabUsageEnabled")
        defaults.set(true, forKey: "clipboardEnabled")

        ExtensionDefaultsMigration.migrate(defaults: defaults)

        let expected: [String: Bool] = [
            "tabAttentionEnabled": true,
            "tabUsageEnabled": false,
            "tabHerdrEnabled": false,
            "tabQuinjetEnabled": false,
            "tabSEOAuditEnabled": false,
            "tabSystemEnabled": true,
            "tabDatabaseEnabled": false,
            "tabCompanionEnabled": false,
            "menuBarSystemStats": false,
            "micMuteEnabled": false,
            "lidAwakeEnabled": false,
            "tabMusicEnabled": true,
            "tabCalendarEnabled": true,
            "notchShelfEnabled": false,
            "clipboardEnabled": true,
            "keystrokeHighlightEnabled": false,
            "focusDimEnabled": false,
            "presenterEnabled": true,
            "colorPickerEnabled": false,
        ]
        for (key, value) in expected {
            #expect(defaults.object(forKey: key) as? Bool == value)
        }
    }

    @Test func priorInstallSeedsSuitesAndSplitAbilities() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "hasPromptedPermissions")
        defaults.set(true, forKey: AppStorageKeys.AppMaintenance.enabled)

        ExtensionDefaultsMigration.migrate(defaults: defaults)

        #expect(defaults.object(forKey: AppStorageKeys.Homebrew.enabled) as? Bool == true)
        #expect(defaults.object(forKey: AppStorageKeys.Cleaner.enabled) as? Bool == true)
        #expect(defaults.object(forKey: AppStorageKeys.Downloads.enabled) as? Bool == true)
        #expect(defaults.bool(forKey: AppStorageKeys.Suites.maintenance))
        #expect(defaults.bool(forKey: AppStorageKeys.Suites.media))
        #expect(defaults.bool(forKey: AppStorageKeys.Suites.system))
        #expect(defaults.bool(forKey: AppStorageKeys.Suites.data))
        #expect(defaults.bool(forKey: AppStorageKeys.Suites.desk))
        #expect(defaults.bool(forKey: AppStorageKeys.Suites.agents))
    }

    @Test func registryMigrationRunsOnlyOnce() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AppStorageKeys.Clipboard.enabled)

        ExtensionDefaultsMigration.migrateRegistry(defaults: defaults)
        #expect(defaults.bool(forKey: AppStorageKeys.Suites.desk))

        defaults.set(false, forKey: AppStorageKeys.Suites.desk)
        ExtensionDefaultsMigration.migrateRegistry(defaults: defaults)
        #expect(!defaults.bool(forKey: AppStorageKeys.Suites.desk))
    }

    @Test func explicitToggleCountsAsPriorInstallEvidence() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "micMuteEnabled")

        ExtensionDefaultsMigration.migrate(defaults: defaults)

        for key in knownDefaultsKeys {
            #expect(defaults.object(forKey: key) is Bool)
        }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "ExtensionRegistryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
