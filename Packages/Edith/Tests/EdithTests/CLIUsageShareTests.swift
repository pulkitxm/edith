import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIUsageShareTests {
    @Test func cardSelectionDefaultsToTheFullSetAndDeduplicates() throws {
        #expect(try UsageShareExport.cards([]) == UsageShareCard.allCases)
        #expect(try UsageShareExport.cards(["all"]) == UsageShareCard.allCases)
        #expect(
            try UsageShareExport.cards(["activity", "busiest", "activity"])
                == [.activity, .busiest])
        #expect(throws: Error.self) { try UsageShareExport.cards(["unknown"]) }
    }

    @Test func anExplicitPNGRequiresOneCard() throws {
        let root = URL(fileURLWithPath: "/tmp/share-tests", isDirectory: true)
        let plan = try UsageShareExport.plan(
            cards: [.activity], output: "card.png", workingDirectory: root,
            now: Date(timeIntervalSince1970: 0))
        #expect(plan.explicitFile?.path == "/tmp/share-tests/card.png")
        #expect(plan.stamp.hasPrefix("1970-01-01-"))
        #expect(throws: Error.self) {
            try UsageShareExport.plan(
                cards: [.activity, .daily], output: "card.png", workingDirectory: root)
        }
    }

    @Test func usageRowsBecomeOneRendererSnapshot() throws {
        let data = Data(
            """
            {
              "generatedAt": "2026-08-29T20:00:00Z",
              "sources": ["codex", "pi"],
              "daily": [
                {
                  "period": "2026-08-28",
                  "bySource": {
                    "codex": [{"modelName":"gpt","inputTokens":100,"outputTokens":20,"cost":1}]
                  },
                  "projects": [{"repositoryID":"edith","repositoryName":"Edith","tokens":120,"cost":1}]
                },
                {
                  "period": "2026-08-29",
                  "bySource": {
                    "pi": [{"modelName":"gpt","inputTokens":200,"outputTokens":30,"cost":2}]
                  }
                }
              ]
            }
            """.utf8)
        let document = try JSONDecoder().decode(UsageDocument.self, from: data)
        let snapshot = UsageShareExport.snapshot(
            document: document, days: document.daily, sources: nil)
        #expect(snapshot.totalTokens == 350)
        #expect(snapshot.agentCount == 2)
        #expect(snapshot.repositoryCount == 1)
        #expect(snapshot.busiestDay?.period == "2026-08-29")
    }
}
