import Foundation

struct PresenterWindowInfo: Equatable, Sendable {
    let ownerName: String
    let title: String
    let width: Double
    let height: Double
    var layer: Int = 0
}

enum PresenterRules {
    struct TitleRule {
        let reason: String
        let owners: [String]
        let titles: [String]
    }

    struct GeometryRule {
        let reason: String
        let owners: [String]
        let width: ClosedRange<Double>
        let height: ClosedRange<Double>
    }

    struct MeetingApp {
        let owner: String
        let name: String
    }

    static let watchedBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.FaceTime",
        "Cisco-Systems.Spark",
        "com.webex.meetingmanager",
        "com.apple.QuickTimePlayerX",
    ]

    static let meetingApps: [MeetingApp] = [
        MeetingApp(owner: "zoom.us", name: "Zoom"),
        MeetingApp(owner: "Microsoft Teams", name: "Teams"),
        MeetingApp(owner: "MSTeams", name: "Teams"),
        MeetingApp(owner: "FaceTime", name: "FaceTime"),
        MeetingApp(owner: "Webex", name: "Webex"),
        MeetingApp(owner: "Cisco Webex", name: "Webex"),
        MeetingApp(owner: "Slack", name: "Slack"),
        MeetingApp(owner: "Discord", name: "Discord"),
        MeetingApp(owner: "Google Chrome", name: "Google Chrome"),
        MeetingApp(owner: "Chromium", name: "Chromium"),
        MeetingApp(owner: "Arc", name: "Arc"),
        MeetingApp(owner: "Safari", name: "Safari"),
        MeetingApp(owner: "Firefox", name: "Firefox"),
        MeetingApp(owner: "Microsoft Edge", name: "Microsoft Edge"),
        MeetingApp(owner: "Brave Browser", name: "Brave"),
    ]

    static let titleRules: [TitleRule] = [
        TitleRule(
            reason: "Zoom share detected",
            owners: ["zoom.us"],
            titles: ["zoom share statusbar window", "meeting toolbar"]),
        TitleRule(
            reason: "Google Meet share detected",
            owners: [
                "Google Chrome", "Google Chrome Helper", "Chromium", "Arc", "Safari", "Firefox",
                "Microsoft Edge", "Brave Browser",
            ],
            titles: ["is sharing your screen", "is sharing a window", "presenting to everyone"]),
        TitleRule(
            reason: "Teams share detected",
            owners: ["Microsoft Teams", "MSTeams"],
            titles: ["sharing your screen", "you're presenting", "meeting controls"]),
        TitleRule(
            reason: "FaceTime share detected",
            owners: ["FaceTime"],
            titles: ["sharing your screen", "screen sharing"]),
        TitleRule(
            reason: "Webex share detected",
            owners: ["Webex"],
            titles: ["sharing your screen", "you're sharing"]),
        TitleRule(
            reason: "Slack huddle share detected",
            owners: ["Slack"],
            titles: ["sharing your screen", "you're sharing"]),
        TitleRule(
            reason: "Discord share detected",
            owners: ["Discord"],
            titles: ["screen share"]),
    ]

    static let geometryRules: [GeometryRule] = [
        GeometryRule(
            reason: "Zoom share detected", owners: ["zoom.us"],
            width: 200...420, height: 30...70)
    ]

    static let systemOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center", "Notification Center",
        "WindowManager",
    ]

    static let menuBarLayer = 24

    static func firstMatch(in windows: [PresenterWindowInfo], titlesAvailable: Bool) -> String? {
        if titlesAvailable, let reason = firstTitleMatch(in: windows) {
            return reason
        }
        return firstGeometryMatch(in: windows)
    }

    static func isListed(_ window: PresenterWindowInfo) -> Bool {
        guard !systemOwners.contains(window.ownerName) else { return false }
        if window.layer == 0 { return window.width >= 40 && window.height >= 20 }
        return window.layer > 0 && window.layer < menuBarLayer && window.width >= 40
            && window.width <= 1000 && window.height <= 160
    }

    static func meetingApp(in windows: [PresenterWindowInfo]) -> String? {
        for window in windows where isListed(window) {
            if let app = meetingApps.first(where: {
                window.ownerName.range(of: $0.owner, options: [.caseInsensitive, .anchored]) != nil
            }) {
                return app.name
            }
        }
        return nil
    }

    private static func firstTitleMatch(in windows: [PresenterWindowInfo]) -> String? {
        for window in windows {
            for rule in rules(for: window.ownerName).titles
            where rule.titles.contains(where: {
                window.title.localizedCaseInsensitiveContains($0)
            }) {
                return rule.reason
            }
        }
        return nil
    }

    private static func firstGeometryMatch(in windows: [PresenterWindowInfo]) -> String? {
        for window in windows {
            for rule in rules(for: window.ownerName).geometry
            where rule.width.contains(window.width) && rule.height.contains(window.height) {
                return rule.reason
            }
        }
        return nil
    }

    struct OwnerRules {
        let titles: [TitleRule]
        let geometry: [GeometryRule]
    }

    static let ownerCacheLimit = 512
    private static let ownerCacheLock = NSLock()
    nonisolated(unsafe) private static var ownerCache: [String: OwnerRules] = [:]

    static func rules(for owner: String) -> OwnerRules {
        if let cached = ownerCacheLock.withLock({ ownerCache[owner] }) { return cached }
        let matches: ([String]) -> Bool = { owners in
            owners.contains { owner.localizedCaseInsensitiveContains($0) }
        }
        let rules = OwnerRules(
            titles: titleRules.filter { matches($0.owners) },
            geometry: geometryRules.filter { matches($0.owners) })
        ownerCacheLock.withLock {
            if ownerCache.count >= ownerCacheLimit { ownerCache.removeAll() }
            ownerCache[owner] = rules
        }
        return rules
    }
}
