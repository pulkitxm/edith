import Foundation
import Testing

@testable import EdithKit

@Suite struct ExtensionRegistryTests {
    private let knownDefaultsKeys: Set<String> = [
        "tabUsageEnabled",
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
        "focusDimEnabled",
        "presenterEnabled",
        "colorPickerEnabled",
    ]

    @Test func registryIdentifiersAreUnique() {
        let identifiers = ExtensionRegistry.entries.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test func registryDefaultsKeysAreUniqueAndComplete() {
        let defaultsKeys = ExtensionRegistry.entries.map(\.defaultsKey)
        #expect(Set(defaultsKeys).count == defaultsKeys.count)
        #expect(Set(defaultsKeys) == knownDefaultsKeys)
    }

    @Test func featuredEntriesArePresent() {
        let featuredIdentifiers = Set(
            ExtensionRegistry.entries.filter(\.featured).map(\.id))
        #expect(featuredIdentifiers == ["usage", "system", "machines", "notchShelf", "clipboard"])
    }

    @Test func toolRequirementsMatchExtensionDependencies() {
        let music = ExtensionRegistry.entries.first { $0.id == "music" }!
        let usage = ExtensionRegistry.entries.first { $0.id == "usage" }!

        #expect(music.requiredTools == [.youtubeDownloader])
        #expect(usage.requiredTools == [.claudeCode, .codex])
        #expect(CLIToolSpec.claudeCode.requirement == .always)
        #expect(
            CLIToolSpec.codex.requirement
                == .whenPreferenceEnabled(key: "codexLimitsEnabled", defaultValue: true))
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

        #expect(titleMatches.map(\.id) == ["usage"])
        #expect(subtitleMatches.map(\.id) == ["calendar"])
        #expect(categoryMatches.allSatisfy { $0.group == .utilities })
        #expect(combinedMatches.map(\.id) == ["presenter"])
    }

    @Test func permissionTiersMatchFeatureRequirements() {
        let required: [String: [ExtensionPermission]] = [
            "usage": [],
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
            "focusDim": [.screenRecording],
            "presenter": [.screenRecording],
            "colorPicker": [.screenRecording],
        ]
        let optional: [String: [ExtensionPermission]] = [
            "usage": [.notifications],
            "system": [.accessibility, .inputMonitoring],
            "machines": [.notifications],
            "companion": [],
            "systemStats": [],
            "micMute": [],
            "lidAwake": [],
            "music": [],
            "calendar": [],
            "notchShelf": [.bluetooth, .camera, .automation],
            "clipboard": [.accessibility],
            "focusDim": [],
            "presenter": [],
            "colorPicker": [],
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

        #expect(clipboard.availability(on: .macOS) == .available)
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
            "tabUsageEnabled": false,
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
