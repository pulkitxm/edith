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

@Suite struct PresenterBroadenedRulesTests {
    @Test(arguments: [
        ("FaceTime", "You are sharing your screen", "FaceTime share detected"),
        ("Webex", "You're sharing your screen", "Webex share detected"),
        ("Cisco Webex Meetings", "You're sharing", "Webex share detected"),
        ("Slack", "Huddle: you're sharing your screen", "Slack huddle share detected"),
        ("Discord", "Screen Share", "Discord share detected"),
        ("Firefox", "meet.google.com is sharing your screen.", "Google Meet share detected"),
        ("Microsoft Edge", "meet.google.com is sharing a window.", "Google Meet share detected"),
        ("Brave Browser", "meet.google.com is sharing your screen.", "Google Meet share detected"),
    ])
    func matchesShareWindows(owner: String, title: String, reason: String) {
        let windows = [
            PresenterWindowInfo(ownerName: owner, title: title, width: 420, height: 60, layer: 3)
        ]
        #expect(PresenterRules.firstMatch(in: windows, titlesAvailable: true) == reason)
    }

    @Test(arguments: [
        ("FaceTime", "FaceTime"),
        ("Webex", "Webex Meetings"),
        ("Slack", "Huddle in #general - Acme - Slack"),
        ("Discord", "#general | Friends - Discord"),
        ("Firefox", "Google Meet - Mozilla Firefox"),
        ("Microsoft Edge", "Sharing tips - Microsoft Edge"),
        ("Finder", "sharing your screen"),
    ])
    func ignoresCallsThatAreNotSharing(owner: String, title: String) {
        let windows = [
            PresenterWindowInfo(ownerName: owner, title: title, width: 1200, height: 800)
        ]
        #expect(PresenterRules.firstMatch(in: windows, titlesAvailable: true) == nil)
    }

    @Test func titlesAreIgnoredWithoutScreenRecordingAccess() {
        let windows = [
            PresenterWindowInfo(
                ownerName: "Discord", title: "Screen Share", width: 800, height: 600)
        ]
        #expect(PresenterRules.firstMatch(in: windows, titlesAvailable: false) == nil)
    }

    @Test func meetingAppIsTheFrontmostListedCallApp() {
        let windows = [
            PresenterWindowInfo(ownerName: "Spotlight Search", title: "", width: 600, height: 60),
            PresenterWindowInfo(
                ownerName: "Dock", title: "", width: 900, height: 80, layer: 20),
            PresenterWindowInfo(ownerName: "Slack", title: "Huddle", width: 900, height: 700),
            PresenterWindowInfo(ownerName: "Google Chrome", title: "Meet", width: 900, height: 700),
        ]
        #expect(PresenterRules.meetingApp(in: windows) == "Slack")
        #expect(PresenterRules.meetingApp(in: Array(windows.prefix(2))) == nil)
    }

    @Test func everyCallAppIsWatched() {
        for id in [
            "com.apple.FaceTime", "Cisco-Systems.Spark", "org.mozilla.firefox",
            "com.microsoft.edgemac", "com.brave.Browser",
        ] {
            #expect(PresenterRules.watchedBundleIDs.contains(id))
        }
    }
}
