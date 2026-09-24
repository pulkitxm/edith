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

    static func firstMatch(in windows: [PresenterWindowInfo], titlesAvailable: Bool) -> String? {
        if titlesAvailable, let reason = firstTitleMatch(in: windows) {
            return reason
        }
        return firstGeometryMatch(in: windows)
    }

    private static func firstTitleMatch(in windows: [PresenterWindowInfo]) -> String? {
        for window in windows {
            for rule in titleRules
            where rule.owners.contains(where: {
                window.ownerName.localizedCaseInsensitiveContains($0)
            }
            ) {
                if rule.titles.contains(where: {
                    window.title.localizedCaseInsensitiveContains($0)
                }) {
                    return rule.reason
                }
            }
        }
        return nil
    }

    private static func firstGeometryMatch(in windows: [PresenterWindowInfo]) -> String? {
        for window in windows {
            for rule in geometryRules
            where rule.owners.contains(where: {
                window.ownerName.localizedCaseInsensitiveContains($0)
            }
            ) {
                if rule.width.contains(window.width), rule.height.contains(window.height) {
                    return rule.reason
                }
            }
        }
        return nil
    }
}
