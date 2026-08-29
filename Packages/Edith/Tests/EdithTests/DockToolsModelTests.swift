import Foundation
import Testing

@testable import EdithKit

@Suite struct DockToolsModelTests {
    @Test func preferencesSanitizeDelayAndExclusions() {
        let preferences = DockToolsPreferences(
            enabled: true, previewMode: .hover, hoverDelay: 4,
            clickAction: .cycleWindows, greenButtonMaximizes: true,
            quitOnLastWindow: false,
            excludedBundleIdentifiers: ["COM.APP.ONE", "com.app.two"])

        #expect(preferences.hoverDelay == DockToolsPreferences.hoverDelayRange.upperBound)
        #expect(preferences.excludes("com.app.one"))
        #expect(preferences.excludes("COM.APP.TWO"))
        #expect(!preferences.excludes("com.app.three"))
        #expect(DockToolsPreferences.sanitizedHoverDelay(.nan) == 0.3)
    }

    @Test func exclusionsRoundTripAsStableCSV() {
        let value = DockToolsPreferences.encodedIdentifiers(
            ["com.example.B", "com.example.a", "com.example.b"])

        #expect(value == "com.example.a,com.example.b")
        #expect(
            DockToolsPreferences.identifiers(" com.example.a,\nCOM.EXAMPLE.B ")
                == ["com.example.a", "com.example.b"])
    }

    @Test func clickPolicyOnlyOverridesTheFrontApp() {
        #expect(
            DockToolsPolicy.shouldHandleDockClick(
                action: .cycleWindows, appIsFrontmost: true, excluded: false))
        #expect(
            !DockToolsPolicy.shouldHandleDockClick(
                action: .standard, appIsFrontmost: true, excluded: false))
        #expect(
            !DockToolsPolicy.shouldHandleDockClick(
                action: .cycleWindows, appIsFrontmost: false, excluded: false))
        #expect(
            !DockToolsPolicy.shouldHandleDockClick(
                action: .cycleWindows, appIsFrontmost: true, excluded: true))
    }

    @Test func quitPolicyRequiresARealLastWindowTransition() {
        #expect(
            DockToolsPolicy.shouldQuit(
                enabled: true, hadWindows: true, hasWindows: false, excluded: false,
                terminated: false, regularApplication: true))
        #expect(
            !DockToolsPolicy.shouldQuit(
                enabled: true, hadWindows: false, hasWindows: false, excluded: false,
                terminated: false, regularApplication: true))
        #expect(
            !DockToolsPolicy.shouldQuit(
                enabled: true, hadWindows: true, hasWindows: false, excluded: true,
                terminated: false, regularApplication: true))
    }

    @Test func adjacentIndexWrapsInBothDirections() {
        #expect(DockToolsPolicy.adjacentIndex(current: 0, count: 3, offset: 1) == 1)
        #expect(DockToolsPolicy.adjacentIndex(current: 2, count: 3, offset: 1) == 0)
        #expect(DockToolsPolicy.adjacentIndex(current: 0, count: 3, offset: -1) == 2)
        #expect(DockToolsPolicy.adjacentIndex(current: nil, count: 3, offset: 1) == 0)
        #expect(DockToolsPolicy.adjacentIndex(current: nil, count: 0, offset: 1) == nil)
    }

    @Test func statusAndWindowPayloadsRoundTrip() throws {
        let preferences = DockToolsPreferences(
            enabled: true, previewMode: .optionClick, hoverDelay: 0.3,
            clickAction: .cycleWindows, greenButtonMaximizes: true,
            quitOnLastWindow: true, excludedBundleIdentifiers: ["com.example.app"])
        let status = DockToolsStatus(
            preferences: preferences, helperRunning: true,
            accessibilityGranted: true, screenRecordingGranted: false)
        let window = DockToolsWindow(
            id: "10:20", title: "", appName: "Example",
            bundleIdentifier: "com.example.app", pid: 10, minimized: true)

        #expect(
            DockToolsIPC.decode(DockToolsStatus.self, from: DockToolsIPC.encode(status)) == status)
        #expect(
            DockToolsIPC.decode([DockToolsWindow].self, from: DockToolsIPC.encode([window]))
                == [window])
        #expect(window.displayTitle == "Example")
        #expect(status.ready)
        #expect(!status.previewsAvailable)
    }
}
