import Foundation

public enum StandupContext {
    public static let prompt = "Concise standup: Yesterday / Today / Blockers. Work only."

    public static func build(
        commits: [String], authoredPRs: [String], reviewedPRs: [String], notionRuns: [String]
    ) -> String {
        var sections: [String] = []
        if !commits.isEmpty {
            sections.append("Commits:\n" + commits.joined(separator: "\n"))
        }
        if !authoredPRs.isEmpty {
            sections.append("PRs authored/merged:\n" + authoredPRs.joined(separator: "\n"))
        }
        if !reviewedPRs.isEmpty {
            sections.append("PRs reviewed:\n" + reviewedPRs.joined(separator: "\n"))
        }
        if !notionRuns.isEmpty {
            sections.append("Agent runs:\n" + notionRuns.joined(separator: "\n"))
        }
        if sections.isEmpty {
            sections.append("No recorded activity for the period.")
        }
        return sections.joined(separator: "\n\n")
    }
}
