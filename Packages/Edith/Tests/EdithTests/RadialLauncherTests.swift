import Carbon.HIToolbox
import Testing

@testable import EdithCLI
import EdithCore
@testable import EdithKit

@Suite struct RadialLauncherTests {
    @Test func starterProfileCoversEveryActionKind() {
        let profile = RadialLauncherProfile.starter

        #expect(profile.items.map(\.kind) == RadialLauncherItemKind.allCases)
        #expect(profile.items.allSatisfy { $0.isConfigured })
        #expect(profile.items.count <= 8)
    }

    @Test func profileStorageRoundTripsAndCapsTheWheel() {
        var profile = RadialLauncherProfile.starter
        profile.name = "Work"
        profile.items = (0..<10).map {
            RadialLauncherItem(
                kind: .link, name: "Link \($0)", payload: "https://example.com/\($0)")
        }

        let decoded = RadialLauncherProfileStore.decode(RadialLauncherProfileStore.encode(profile))

        #expect(decoded.name == "Work")
        #expect(decoded.items.count == 8)
        #expect(decoded.items == Array(profile.items.prefix(8)))
    }

    @Test func invalidProfileFallsBackToStarter() {
        #expect(
            RadialLauncherProfileStore.decode(nil).items.map(\.kind)
                == RadialLauncherItemKind.allCases)
        #expect(
            RadialLauncherProfileStore.decode("not json").items.map(\.kind)
                == RadialLauncherItemKind.allCases)
        #expect(RadialLauncherProfileStore.decodeIfValid("not json") == nil)
    }

    @Test func itemValidationMatchesExecutionRequirements() {
        #expect(!RadialLauncherItem(kind: .application, name: "Empty").isConfigured)
        #expect(RadialLauncherItem(kind: .file, name: "Home", payload: "~").isConfigured)
        #expect(
            RadialLauncherItem(kind: .link, name: "Web", payload: "https://edith.app").isConfigured)
        #expect(
            !RadialLauncherItem(kind: .link, name: "Local", payload: "file:///tmp").isConfigured)
        #expect(
            RadialLauncherItem(
                kind: .keyCombination, name: "Copy", payload: "⌘C", keyCode: kVK_ANSI_C,
                modifiers: cmdKey
            ).isConfigured)
        #expect(
            RadialLauncherItem(
                kind: .media, name: "Next", payload: RadialLauncherMediaAction.next.rawValue
            ).isConfigured)
        #expect(
            RadialLauncherItem(
                kind: .edith, name: "Panel",
                payload: RadialLauncherEdithAction.openPanel.rawValue
            ).isConfigured)
    }

    @Test func emptyNamesUseTheActionKind() {
        let item = RadialLauncherItem(kind: .media, name: "  ", payload: "next")

        #expect(item.displayName == "Media control")
        #expect(item.effectiveSymbol == "forward.fill")
    }

    @Test func selectionStartsAtTopAndMovesClockwise() {
        #expect(RadialLauncherSelection.index(dx: 0, dy: 10, itemCount: 4, deadZone: 20) == nil)
        #expect(RadialLauncherSelection.index(dx: 0, dy: 100, itemCount: 4, deadZone: 20) == 0)
        #expect(RadialLauncherSelection.index(dx: 100, dy: 0, itemCount: 4, deadZone: 20) == 1)
        #expect(RadialLauncherSelection.index(dx: 0, dy: -100, itemCount: 4, deadZone: 20) == 2)
        #expect(RadialLauncherSelection.index(dx: -100, dy: 0, itemCount: 4, deadZone: 20) == 3)
        #expect(RadialLauncherSelection.index(dx: 100, dy: 0, itemCount: 0, deadZone: 20) == nil)
    }

    @Test func extensionSurfacesStayRegistered() throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "radialLauncher" })
        let lifecycle = try #require(entry.lifecycle)

        #expect(entry.defaultsKey == RadialLauncherPreferenceKeys.enabled)
        #expect(entry.requiredCapabilities == [.globalShortcuts])
        #expect(entry.optionalCapabilities == [.mediaControls])
        #expect(entry.optionalPermissions == [.accessibility])
        #expect(lifecycle.cliExamples.contains("ed radial show"))
        #expect(lifecycle.documentation.map(\.path).contains("docs/cli/radial/README.md"))
    }

    @Test func configurationKeysShareTheRadialGroup() {
        let keys = [
            RadialLauncherPreferenceKeys.enabled, RadialLauncherPreferenceKeys.profile,
            RadialLauncherPreferenceKeys.atPointer, RadialLauncherPreferenceKeys.hotKeyCode,
            RadialLauncherPreferenceKeys.hotKeyMods, RadialLauncherPreferenceKeys.hotKeyLabel,
        ]

        #expect(keys.allSatisfy { ConfigCatalog.definition(for: $0)?.group == "radial" })
        #expect(
            ConfigCatalog.definition(for: RadialLauncherPreferenceKeys.atPointer)?.fallback
                == .bool(true))
        #expect(
            ConfigCatalog.definition(for: RadialLauncherPreferenceKeys.hotKeyCode)?.fallback
                == .int(kVK_Space))
    }

    @Test func liveReadinessChecksProfileContentAndShortcutStorage() {
        let suite = "test.radial-launcher.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(
            ExtensionLiveAdapters.radialLauncherReadiness(defaults: defaults)
                == .ready("Configured radial actions: 6."))
        defaults.set(
            RadialLauncherProfileStore.encode(RadialLauncherProfile(name: "Empty", items: [])),
            forKey: RadialLauncherPreferenceKeys.profile)
        #expect(
            ExtensionLiveAdapters.radialLauncherReadiness(defaults: defaults)
                == .empty("Add at least one complete action to the radial profile."))
        defaults.set("invalid", forKey: RadialLauncherPreferenceKeys.profile)
        #expect(
            ExtensionLiveAdapters.radialLauncherReadiness(defaults: defaults)
                == .needsSetup("The stored profile or global shortcut is invalid."))
        defaults.removeObject(forKey: RadialLauncherPreferenceKeys.profile)
        defaults.set(0, forKey: RadialLauncherPreferenceKeys.hotKeyMods)
        #expect(
            ExtensionLiveAdapters.radialLauncherReadiness(defaults: defaults)
                == .needsSetup("The stored profile or global shortcut is invalid."))
    }

    @Test func operationsAndCommandsStayInParity() throws {
        for operation in RadialLauncherOperation.allCases {
            #expect(
                UserOperationCatalog.descriptor(id: operation.descriptor.id) == operation.descriptor
            )
            #expect(
                UserOperationCatalog.descriptor(cli: operation.descriptor.cli)
                    == operation.descriptor)
        }

        #expect(try EdRoot.parseAsRoot(["radial", "show", "--json"]) is RadialShowCommand)
        #expect(try EdRoot.parseAsRoot(["radial", "profile", "--json"]) is RadialProfileCommand)
        #expect(try EdRoot.parseAsRoot(["radial"]) is RadialProfileCommand)
    }
}
