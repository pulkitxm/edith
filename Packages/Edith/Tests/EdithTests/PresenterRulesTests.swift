import Testing
@testable import EdithHelper

@Suite struct PresenterRulesTests {
    @Test func matchesZoomShareTitle() {
        let windows = [
            PresenterWindowInfo(
                ownerName: "zoom.us", title: "zoom share statusbar window", width: 300, height: 50)
        ]
        #expect(
            PresenterRules.firstMatch(in: windows, titlesAvailable: true) == "Zoom share detected")
    }

    @Test func matchesGoogleMeetShareTitleInChrome() {
        let windows = [
            PresenterWindowInfo(
                ownerName: "Google Chrome", title: "You are presenting to everyone", width: 800,
                height: 600)
        ]
        #expect(
            PresenterRules.firstMatch(in: windows, titlesAvailable: true)
                == "Google Meet share detected")
    }

    @Test func ignoresUnrelatedWindows() {
        let windows = [
            PresenterWindowInfo(ownerName: "Finder", title: "Downloads", width: 800, height: 600)
        ]
        #expect(PresenterRules.firstMatch(in: windows, titlesAvailable: true) == nil)
    }

    @Test func withoutTitlesFallsBackToGeometry() {
        let windows = [
            PresenterWindowInfo(ownerName: "zoom.us", title: "", width: 300, height: 50)
        ]
        #expect(
            PresenterRules.firstMatch(in: windows, titlesAvailable: false) == "Zoom share detected")
    }

    @Test func withoutTitlesIgnoresNonMatchingGeometry() {
        let windows = [
            PresenterWindowInfo(ownerName: "zoom.us", title: "", width: 1200, height: 800)
        ]
        #expect(PresenterRules.firstMatch(in: windows, titlesAvailable: false) == nil)
    }

    @Test func titlesAvailableStillFallsBackToGeometryWhenTitleMissing() {
        let windows = [
            PresenterWindowInfo(ownerName: "zoom.us", title: "", width: 300, height: 50)
        ]
        #expect(
            PresenterRules.firstMatch(in: windows, titlesAvailable: true) == "Zoom share detected")
    }
}
