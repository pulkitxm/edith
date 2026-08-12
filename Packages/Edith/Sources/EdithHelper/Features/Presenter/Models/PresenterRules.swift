import Foundation

struct PresenterWindowInfo {
    let ownerName: String
    let title: String
    let width: Double
    let height: Double
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

    static let titleRules: [TitleRule] = [
        TitleRule(
            reason: "Zoom share detected",
            owners: ["zoom.us"],
            titles: ["zoom share statusbar window", "meeting toolbar"]),
        TitleRule(
            reason: "Google Meet share detected",
            owners: ["Google Chrome", "Google Chrome Helper", "Chromium", "Arc", "Safari"],
            titles: ["is sharing your screen", "presenting to everyone"]),
        TitleRule(
            reason: "Teams share detected",
            owners: ["Microsoft Teams", "MSTeams"],
            titles: ["sharing your screen", "you're presenting", "meeting controls"]),
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
