@testable import EdithKit
import Foundation
import Testing

@Suite struct CodeStatsIdentitySuggestionTests {
    private func author(_ name: String, _ email: String, _ commits: Int = 5) -> CodeStatsAuthor {
        CodeStatsAuthor(name: name, email: email, commits: commits)
    }

    @Test func ranksNoreplyHostnameNameAndVariantMatches() {
        let identity = CodeStatsIdentity(emails: ["p@work.com"])
        let suggestions = CodeStatsIdentitySuggester.suggestions(
            authors: [
                author("pulkit", "pulkit@Pulkits-MacBook-Pro.local", 40),
                author("Someone", "4242+pulkitxm@users.noreply.github.com", 3),
                author("Pulkit Mittal", "pm@gmail.com", 12),
                author("pulkitx", "px@gmail.com", 2),
                author("Stranger", "s@x.com", 900),
                author("Claude", "noreply@anthropic.com", 500),
                author("dependabot[bot]", "49699333+dependabot[bot]@users.noreply.github.com", 80),
                author("pulkitxm", "p@work.com", 70),
            ],
            identity: identity, login: "pulkitxm", name: "Pulkit Mittal")
        #expect(
            suggestions.map(\.value) == [
                "4242+pulkitxm@users.noreply.github.com", "pulkit@Pulkits-MacBook-Pro.local",
                "pm@gmail.com", "px@gmail.com",
            ])
        #expect(
            suggestions.map(\.reason) == [.noreply, .hostname, .sameName, .variant])
        let afterAdding = CodeStatsIdentitySuggester.filtered(
            suggestions,
            identity: CodeStatsIdentity(emails: ["p@work.com", "pm@gmail.com"]))
        #expect(!afterAdding.map(\.value).contains("pm@gmail.com"))
    }

    @Test func nothingIsSuggestedWithoutReferences() {
        #expect(
            CodeStatsIdentitySuggester.suggestions(
                authors: [author("a", "a@x.com")], identity: CodeStatsIdentity(), login: nil,
                name: nil
            ).isEmpty)
    }
}
