import Testing

@testable import EdithKit

@Suite struct StandupContextTests {
    @Test func joinsNonEmptySectionsOnly() {
        let context = StandupContext.build(
            commits: ["- did a thing (abc123)"], authoredPRs: [], reviewedPRs: [],
            notionRuns: ["- ran an agent"])
        #expect(context.contains("Commits:"))
        #expect(context.contains("did a thing"))
        #expect(!context.contains("PRs authored/merged:"))
        #expect(context.contains("Agent runs:"))
    }

    @Test func fallsBackWhenNothingGathered() {
        let context = StandupContext.build(
            commits: [], authoredPRs: [], reviewedPRs: [], notionRuns: [])
        #expect(context == "No recorded activity for the period.")
    }
}
