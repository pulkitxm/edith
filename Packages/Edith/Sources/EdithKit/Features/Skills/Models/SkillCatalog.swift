import Foundation

public struct EdithSkill: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let detail: String
    public let symbol: String

    public var sourceURL: URL {
        URL(
            string:
                "https://raw.githubusercontent.com/pulkitxm/edith/main/Packages/Edith/skills/\(id)/SKILL.md"
        )!
    }

    public var packageURL: URL {
        URL(
            string:
                "https://github.com/pulkitxm/edith/tree/main/Packages/Edith/skills/\(id)"
        )!
    }

}

public enum EdithSkillLibrary {
    public static let skills: [EdithSkill] = [
        EdithSkill(
            id: "edith-remote-work", name: "Edith Remote Work",
            summary: "Your harness here. Your projects on any Edith machine.",
            detail:
                "Discover connected machines, explore their projects, and run edits, builds, tests and containers through the ed CLI.",
            symbol: "terminal"),
        EdithSkill(
            id: "edith-video-edit", name: "Edith Video Edit",
            summary: "Original media to a native edit, from the command line.",
            detail:
                "Plan frame-accurate cuts, reuse source media, arrange audio and beats, and apply verified edits without opening an editor.",
            symbol: "film"),
        EdithSkill(
            id: "edith-video-delivery", name: "Edith Video Delivery",
            summary: "Review the finished cut and verify the actual export.",
            detail:
                "Render native projects at the requested quality, inspect frames and contact sheets, and verify delivery properties and media dependencies.",
            symbol: "checkmark.rectangle.stack"),
    ]
}

public enum SkillsError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
