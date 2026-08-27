import Foundation
import Testing

@testable import Edith
@testable import EdithCore
@testable import EdithKit

@Suite struct ExtensionRegistryTests {
    private let knownDefaultsKeys: Set<String> = [
        "tabAttentionEnabled",
        "tabUsageEnabled",
        "tabHerdrEnabled",
        "tabQuinjetEnabled",
        "tabSystemEnabled",
        "tabMachinesEnabled",
        "tabCompanionEnabled",
        "menuBarSystemStats",
        "micMuteEnabled",
        "lidAwakeEnabled",
        "tabMusicEnabled",
        "tabCalendarEnabled",
        "notchShelfEnabled",
        "clipboardEnabled",
        "finderToolsEnabled",
        "focusDimEnabled",
        "presenterEnabled",
        "colorPickerEnabled",
        "windowToolsEnabled",
        "emojiEnabled",
    ]

    @Test func registryIdentifiersAreUnique() {
        let identifiers = ExtensionRegistry.entries.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
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

        for descriptor in ExtensionLifecycleCatalog.descriptors {
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
    }

    @Test func featuredEntriesArePresent() {
        let featuredIdentifiers = Set(
            ExtensionRegistry.entries.filter(\.featured).map(\.id))
        #expect(
            featuredIdentifiers == [
                "attention", "usage", "herdr", "quinjet", "system", "machines", "notchShelf",
                "clipboard",
            ])
    }

    @Test func toolRequirementsMatchExtensionDependencies() {
        let music = ExtensionRegistry.entries.first { $0.id == "music" }!
        let usage = ExtensionRegistry.entries.first { $0.id == "usage" }!
        let quinjet = ExtensionRegistry.entries.first { $0.id == "quinjet" }!

        #expect(music.requiredTools.isEmpty)
        #expect(music.optionalTools == [.youtubeDownloader])
        #expect(usage.requiredTools == [.claudeCode, .codex])
        #expect(usage.optionalTools.isEmpty)
        #expect(quinjet.requiredTools == [.quinjet])
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
            #expect(!entry.isEnabled(in: defaults))
            #expect(ConfigCatalog.definition(for: entry.defaultsKey)?.fallback == .bool(false))
        }
    }

    @Test func marketplaceFilterMatchesQueryAndCategory() {
        let titleMatches = ExtensionMarketplaceFilter.filter(
            entries: ExtensionRegistry.entries, query: "AGENT", category: .all)
        let subtitleMatches = ExtensionMarketplaceFilter.filter(
            entries: ExtensionRegistry.entries, query: "schedule", category: .all)
        let categoryMatches = ExtensionMarketplaceFilter.filter(
            entries: ExtensionRegistry.entries, query: "", category: .utilities)
        let combinedMatches = ExtensionMarketplaceFilter.filter(
            entries: ExtensionRegistry.entries, query: "screen", category: .utilities)
        let attentionMatches = ExtensionMarketplaceFilter.filter(
            entries: ExtensionRegistry.entries, query: "attention", category: .all)

        #expect(titleMatches.map(\.id) == ["usage"])
        #expect(subtitleMatches.map(\.id) == ["calendar"])
        #expect(categoryMatches.allSatisfy { $0.group == .utilities })
        #expect(combinedMatches.map(\.id) == ["presenter"])
        #expect(attentionMatches.map(\.id) == ["attention"])
    }

    @Test func marketplaceTextSearchIgnoresAStaleCategory() {
        for category in [
            ExtensionMarketplaceCategory.agent, .system, .media,
        ] {
            let matches = ExtensionMarketplaceFilter.filter(
                entries: ExtensionRegistry.entries, query: " attention ", category: category)
            #expect(matches.map(\.id) == ["attention"])
        }
    }

    @Test func marketplaceEmptyStateExplainsSearchAndCategory() {
        let search = ExtensionMarketplaceFilter.emptyState(
            query: " missing extension ", category: .agent)
        #expect(search.title == "No extensions found")
        #expect(search.detail == "No extension matches \"missing extension\". Try another search.")

        let category = ExtensionMarketplaceFilter.emptyState(query: "", category: .utilities)
        #expect(category.title == "No Utilities extensions")
        #expect(category.detail == "No extensions are available in this category.")

        let marketplace = ExtensionMarketplaceFilter.emptyState(query: "  ", category: .all)
        #expect(marketplace.title == "No extensions available")
        #expect(marketplace.detail == "No extensions are registered yet.")
    }

    @Test func permissionTiersMatchFeatureRequirements() {
        let required: [String: [ExtensionPermission]] = [
            "attention": [],
            "usage": [],
            "herdr": [],
            "quinjet": [],
            "system": [],
            "machines": [],
            "companion": [],
            "systemStats": [],
            "micMute": [],
            "lidAwake": [],
            "music": [],
            "calendar": [.calendar],
            "notchShelf": [],
            "clipboard": [],
            "finderTools": [.accessibility],
            "focusDim": [.screenRecording],
            "presenter": [.screenRecording],
            "colorPicker": [.screenRecording],
            "windowTools": [.accessibility],
            "emoji": [],
        ]
        let optional: [String: [ExtensionPermission]] = [
            "attention": [],
            "usage": [.notifications],
            "herdr": [],
            "quinjet": [],
            "system": [.accessibility, .inputMonitoring],
            "machines": [.notifications],
            "companion": [],
            "systemStats": [.notifications],
            "micMute": [],
            "lidAwake": [],
            "music": [],
            "calendar": [],
            "notchShelf": [.applicationAudio, .bluetooth, .camera, .automation],
            "clipboard": [.accessibility],
            "finderTools": [.automation],
            "focusDim": [],
            "presenter": [],
            "colorPicker": [],
            "windowTools": [],
            "emoji": [.accessibility],
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
        let clipboard = ExtensionRegistry.entries.first { $0.id == "clipboard" }!
        let notchShelf = ExtensionRegistry.entries.first { $0.id == "notchShelf" }!
        let macOS143 = PlatformCapabilities.macOS(
            version: OperatingSystemVersion(majorVersion: 14, minorVersion: 3, patchVersion: 0))
        let macOS144 = PlatformCapabilities.macOS(
            version: OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0))

        #expect(clipboard.availability(on: .macOS) == .available)
        #expect(
            macOS143.state(for: .applicationAudio)
                == .unsupported("Application audio mixing requires macOS 14.4 or later."))
        #expect(notchShelf.availability(on: macOS143) == .degraded([.applicationAudio]))
        #expect(macOS144.state(for: .applicationAudio) == .permissionRequired)
        #expect(notchShelf.availability(on: macOS144) == .available)
    }

    @Test func capabilityTiersDoNotOverlap() {
        for entry in ExtensionRegistry.entries {
            #expect(!entry.requiredCapabilities.isEmpty)
            #expect(
                Set(entry.requiredCapabilities).isDisjoint(with: entry.optionalCapabilities))
        }
    }

    @Test func missingRequiredPermissionsShowSheet() {
        let entry = ExtensionRegistry.entries.first { $0.id == "presenter" }!
        let decision = ExtensionPermissionFlow.decision(
            for: entry, granted: [.screenRecording: false], hasSeenPermissions: true)
        #expect(
            decision
                == .showSheet(
                    required: [.screenRecording], optional: []))
    }

    @Test func grantedRequiredPermissionsEnableDirectly() {
        let entry = ExtensionRegistry.entries.first { $0.id == "presenter" }!
        let decision = ExtensionPermissionFlow.decision(
            for: entry, granted: [.screenRecording: true], hasSeenPermissions: false)
        #expect(decision == .enableDirectly)
    }

    @Test func unseenSystemPermissionsAreOptional() {
        let entry = ExtensionRegistry.entries.first { $0.id == "system" }!
        let decision = ExtensionPermissionFlow.decision(
            for: entry, granted: [.accessibility: true, .inputMonitoring: false],
            hasSeenPermissions: false)
        #expect(decision == .enableDirectly)
    }

    @Test func unseenMissingOptionalPermissionsEnableDirectly() {
        let entry = ExtensionRegistry.entries.first { $0.id == "notchShelf" }!
        let decision = ExtensionPermissionFlow.decision(
            for: entry, granted: [.bluetooth: false, .camera: true],
            hasSeenPermissions: false)
        #expect(decision == .enableDirectly)
    }

    @Test func seenOptionalPermissionsEnableDirectly() {
        let entry = ExtensionRegistry.entries.first { $0.id == "notchShelf" }!
        let decision = ExtensionPermissionFlow.decision(
            for: entry, granted: [.bluetooth: false, .camera: false],
            hasSeenPermissions: true)
        #expect(decision == .enableDirectly)
    }

    @Test func grantedOptionalPermissionsEnableDirectlyWithoutPriorEnable() {
        let entry = ExtensionRegistry.entries.first { $0.id == "clipboard" }!
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
            "tabSystemEnabled": true,
            "tabMachinesEnabled": false,
            "tabCompanionEnabled": false,
            "menuBarSystemStats": false,
            "micMuteEnabled": false,
            "lidAwakeEnabled": false,
            "tabMusicEnabled": true,
            "tabCalendarEnabled": true,
            "notchShelfEnabled": false,
            "clipboardEnabled": true,
            "finderToolsEnabled": false,
            "focusDimEnabled": false,
            "presenterEnabled": true,
            "colorPickerEnabled": false,
        ]
        for (key, value) in expected {
            #expect(defaults.object(forKey: key) as? Bool == value)
        }
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
