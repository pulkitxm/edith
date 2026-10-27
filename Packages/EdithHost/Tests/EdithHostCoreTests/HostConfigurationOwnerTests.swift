import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@MainActor @Suite struct HostConfigurationOwnerTests {
    private nonisolated static let families: [String: [String]] = [
        "micMute": [
            "micMuted", "micMuteEnabled", "micMuteInMenuBar", "micHotKeyCode",
            "micHotKeyMods", "micHotKeyLabel",
        ],
        "focusDim": [
            "focusDimActive", "focusDimEnabled", "focusDimIntensity", "focusDimAnimationDuration",
            "focusDimOtherDisplaysMode", "focusDimHotKeyCode", "focusDimHotKeyMods",
            "focusDimHotKeyLabel",
        ],
        "hinge": [
            "hingeActive", "hingeEnabled", "hingeOpenAngle", "hingeEffectStrength",
            "hingeSideFill", "hingeCropsTop", "hingeBlursByDistance", "hingeHotKeyCode",
            "hingeHotKeyMods", "hingeHotKeyLabel",
        ],
        "windowSweaters": [
            "windowSweatersEnabled", "windowSweatersActive", "windowSweatersPattern",
            "windowSweatersStitch", "windowSweatersBasket", "windowSweatersBorderWidth",
            "windowSweatersGauge", "windowSweatersAnchor", "windowSweatersOrder",
            "windowSweatersUnfocusedDim", "windowSweatersAccessibilityFocus",
            "windowSweatersExcludedApps",
        ],
        "presenter": [
            "presenterEnabled", "presenterMode", "presenterAutoActive", "presenterAutoPaused",
            "presenterAutoReason", "presenterAutoEnabled", "presenterDetectRecording",
            "presenterDetectScreenSharing", "presenterDetectMirroring", "presenterAskJev",
            "presenterHideMenuBarNumbers", "presenterBlurMusic", "presenterBlurMoney",
            "presenterBlurUsage", "presenterBlurCalendar", "presenterBlurAgents",
            "presenterBlurAttention", "presenterBlurCamera", "presenterBlurStudio",
            "presenterBlurDatabase", "presenterBlurMemory", "presenterBlurFleet",
            "presenterBlurReview", "presenterBlurSiteAudit", "presenterBlurRunningApps",
            "presenterBlurShelf", "presenterBlurBrowser", "presenterHotKeyCode",
            "presenterHotKeyMods", "presenterHotKeyLabel",
        ],
        "keystrokeHighlight": [
            "keystrokeHighlightEnabled", "keystrokeHighlightActive", "keystrokeHighlightDuration",
            "keystrokeHighlightPosition", "keystrokeHighlightHotKeyCode",
            "keystrokeHighlightHotKeyMods", "keystrokeHighlightHotKeyLabel",
        ],
        "keepAwake": ["keepAwakeEnabled", "preventSleep"],
        "lidAwake": [
            "lidAwakeEnabled", "lidAwakeRestoreOnQuit", "lidAwakeSession",
            "lidAwakeBatteryThreshold", "lidAwakeActive",
        ],
        "appMaintenance": [
            "appMaintenanceEnabled", "appMaintenanceInstallDestination", "appUpdateAutoRefresh",
            "appUpdateRefreshInterval", "appUpdateNotifications", "appUpdateConcurrency",
            "appUpdateRetries", "appMaintenanceCategoriesExpanded",
        ],
        "cleaner": [
            "cleanerEnabled", "cleanerSelectedDrives", "cleanerCustomFolders",
            "cleanerCategoryDefaults", "cleanerSelectionOverrides",
        ],
        "homebrew": ["homebrewEnabled", "homebrewDefaultKind"],
        "system": ["tabSystemEnabled", "systemAppsSort", "systemAppsSortAsc"],
    ]

    @MainActor private struct Fixture {
        let shared: UserDefaults
        let owner: UserDefaults
        let names: [String]
        let service: HostConfigurationCLI
        var announced: () -> Int

        init(availability: HostOwnerAvailability = .ready) throws {
            let id = UUID().uuidString
            names = [
                "com.pulkit.edith.tests.owner-shared-\(id)", "com.pulkit.edith.tests.owner-\(id)",
            ]
            shared = try #require(UserDefaults(suiteName: names[0]))
            owner = try #require(UserDefaults(suiteName: names[1]))
            let owner = owner
            final class Counter { var value = 0 }
            let counter = Counter()
            service = try HostConfigurationCLI(
                shared: shared, standard: shared,
                owners: { _ in owner }, availability: { _ in availability },
                changed: { counter.value += 1 })
            announced = { counter.value }
        }

        func clean() { names.forEach { shared.removePersistentDomain(forName: $0) } }
    }

    @Test(arguments: families.keys.sorted()) func everyOriginalKeyOfTheFamilyIsOwned(
        _ owner: String
    ) throws {
        let owned = HostConfigurationCLI.applicationSettings.filter { $0.owner == owner }
        #expect(Set(owned.map(\.key)) == Set(try #require(Self.families[owner])))
        #expect(owned.count == Self.families[owner]?.count)
    }

    @Test func familiesStayDisjointFromHostKeys() {
        let keys = HostConfigurationCLI.applicationSettings.map(\.key)
        #expect(Set(keys).count == keys.count)
        let hostOwned = HostConfigurationCLI.applicationSettings.filter { $0.owner == nil }
        #expect(Set(hostOwned.map(\.key)).isDisjoint(with: Self.families.values.flatMap { $0 }))
    }

    @Test(arguments: [
        ("focusDimIntensity", "0.7", "number"), ("micMuteInMenuBar", "true", "bool"),
        ("hingeSideFill", "black", "string"), ("windowSweatersBorderWidth", "20", "number"),
        ("presenterBlurUsage", "true", "bool"), ("keystrokeHighlightPosition", "top", "string"),
        ("preventSleep", "true", "bool"), ("lidAwakeBatteryThreshold", "30", "int"),
        ("appUpdateConcurrency", "3", "int"), ("homebrewDefaultKind", "cask", "string"),
        ("systemAppsSortAsc", "true", "bool"),
    ]) func writesGoToTheOwnerSuiteAndAnnounce(_ key: String, _ value: String, _ type: String)
        throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let before = fixture.announced()
        _ = try fixture.service.execute(["set", key, value])
        #expect(fixture.owner.object(forKey: key) != nil)
        #expect(fixture.shared.object(forKey: key) == nil)
        #expect(fixture.announced() == before + 1)
        let described = try JSONDecoder().decode(
            HostCLIJSON.self,
            from: Data(try fixture.service.execute(["describe", key, "--json"]).stdout.utf8)
        ).object
        #expect(described?["isSet"] == .bool(true) && described?["type"]?.string == type)
        _ = try fixture.service.execute(["unset", key])
        #expect(fixture.owner.object(forKey: key) == nil)
    }

    @Test func readsComeFromTheOwnerSuiteNotTheHostOne() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.shared.set(0.9, forKey: "focusDimIntensity")
        fixture.owner.set(0.3, forKey: "focusDimIntensity")
        #expect(try fixture.service.execute(["get", "focusDimIntensity"]).stdout == "0.3\n")
        #expect(
            try fixture.service.execute(["ls", "--changed", "focusDimIntensity"]).stdout
                .contains("0.3"))
    }

    @Test func extensionToggleKeysAreReadOnly() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let toggles = [
            "micMuteEnabled", "focusDimEnabled", "hingeEnabled", "windowSweatersEnabled",
            "presenterEnabled", "keystrokeHighlightEnabled", "keepAwakeEnabled",
            "lidAwakeEnabled", "appMaintenanceEnabled", "cleanerEnabled", "homebrewEnabled",
            "tabSystemEnabled",
        ]
        for key in toggles {
            #expect(throws: HostCLIError.self) {
                try fixture.service.execute(["set", key, "true"])
            }
        }
        #expect(fixture.owner.persistentDomain(forName: fixture.names[1]) == nil)
    }

    @Test func importAndExportRoundTripThroughTheOwnerSuite() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let input = Data(
            "{\"presenterAutoEnabled\":true,\"cleanerSelectedDrives\":[\"/\"],\"lidAwakeSession\":\"oneHour\"}"
                .utf8)
        _ = try fixture.service.execute(["import", "-", "--json"], input: input)
        #expect(fixture.owner.bool(forKey: "presenterAutoEnabled"))
        #expect(fixture.owner.stringArray(forKey: "cleanerSelectedDrives") == ["/"])
        #expect(fixture.owner.string(forKey: "lidAwakeSession") == "oneHour")
        #expect(fixture.shared.object(forKey: "presenterAutoEnabled") == nil)
        let exported = try JSONDecoder().decode(
            HostCLIJSON.self, from: Data(try fixture.service.execute(["export"]).stdout.utf8)
        ).object
        #expect(exported?["lidAwakeSession"] == .string("oneHour"))
    }

    @Test func settingsWithoutAnOwnerStillUseTheHostSuites() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.service.execute(["set", "appearance", "dark"])
        #expect(fixture.shared.string(forKey: "appearance") == "dark")
        #expect(fixture.owner.object(forKey: "appearance") == nil)
    }

    @Test(arguments: [
        (HostOwnerAvailability.off, "ed extensions enable presenter"),
        (HostOwnerAvailability.notInstalled, "ed extensions install presenter"),
    ]) func writesToAnUnavailableOwnerFailWithTheRecoveryCommand(
        _ availability: HostOwnerAvailability, _ hint: String
    ) throws {
        let fixture = try Fixture(availability: availability)
        defer { fixture.clean() }
        for arguments in [
            ["set", "presenterAutoEnabled", "true"], ["unset", "presenterAutoEnabled"],
        ] {
            let error = #expect(throws: HostCLIError.self) {
                try fixture.service.execute(arguments)
            }
            #expect(error?.errorDescription?.contains(hint) == true)
        }
        let input = Data("{\"presenterAutoEnabled\":true}".utf8)
        #expect(throws: HostCLIError.self) {
            try fixture.service.execute(["import", "-", "--json"], input: input)
        }
        #expect(fixture.owner.object(forKey: "presenterAutoEnabled") == nil)
        #expect(try fixture.service.execute(["get", "presenterAutoEnabled"]).stdout == "\n")
        _ = try fixture.service.execute(["set", "appearance", "dark"])
    }
}
