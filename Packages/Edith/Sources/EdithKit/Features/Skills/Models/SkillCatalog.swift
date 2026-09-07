import Foundation

public struct EdithSkill: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let detail: String
    public let symbol: String

    public var directory: URL? {
        Bundle.module.url(forResource: "skills", withExtension: nil)?.appendingPathComponent(id)
    }
}

public enum EdithSkillLibrary {
    public static let skills: [EdithSkill] = [
        EdithSkill(
            id: "edith-remote-work", name: "Edith Remote Work",
            summary: "Your harness here. Your projects on any Edith machine.",
            detail:
                "Discover connected machines, explore their projects, and run edits, builds, tests and containers through the ed CLI.",
            symbol: "terminal")
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
