import Foundation
import Testing

#if canImport(Translation)
import Translation
#endif

@testable import EdithStudio

@Suite struct IntelligenceToolsTests {
    static let article = """
        # Solar Adoption

        Rooftop solar installations in the town doubled over the last two years.

        The council approved a grant that covers a third of installation costs for homeowners.

        Battery storage is now included in half of new installations.
        """

    @Test func summarizeReportsMissingAppleIntelligence() async throws {
        let space = try Workspace()
        let source = space.url("article.md")
        try Self.article.write(to: source, atomically: true, encoding: .utf8)
        var environment = space.environment
        environment.appleIntelligenceAvailable = false
        await #expect(throws: StudioError.self) {
            try await space.run("ai.summarize", [source], environment: environment)
        }
        let tool = try #require(StudioCatalog.tool("ai.summarize"))
        #expect(environment.missing(for: tool) == [.appleIntelligence])
    }

    @Test func summarizeWritesMarkdownWhenAvailable() async throws {
        guard StudioIntelligence.isModelAvailable else { return }
        let space = try Workspace()
        let source = space.url("article.md")
        try Self.article.write(to: source, atomically: true, encoding: .utf8)
        do {
            let result = try await space.run("ai.summarize", [source], ["length": .text("short")])
            let summary = try String(contentsOf: try result.url())
            #expect(summary.hasPrefix("# Summary of article"))
            #expect(summary.count > 40)
        } catch let error as StudioError {
            if case .failed = error { return }
            throw error
        }
    }

    @Test func summarizeRejectsDocumentsWithoutText() async throws {
        let space = try Workspace()
        let source = space.url("blank.pdf")
        try Fixtures.pdf(at: source, pages: [""])
        var environment = space.environment
        environment.appleIntelligenceAvailable = true
        await #expect(throws: StudioError.self) {
            try await space.run("ai.summarize", [source], environment: environment)
        }
    }

    @Test func chunkingRespectsTheLimit() {
        let text = (1...200).map { "Sentence number \($0) in a long paragraph." }.joined(
            separator: "\n")
        let chunks = StudioSummarizer.chunks(text, limit: 500)
        #expect(chunks.count > 5)
        #expect(chunks.allSatisfy { $0.count <= 500 })
        #expect(chunks.joined(separator: "\n") == text)
        let long = String(repeating: "x", count: 1200)
        #expect(StudioSummarizer.chunks(long, limit: 500).map(\.count) == [500, 500, 200])
    }

    @Test func translateNeedsInstalledLanguagesOrTranslates() async throws {
        let space = try Workspace()
        let source = space.url("note.md")
        try "# Welcome\n\nThe meeting starts at noon.\n\n- Bring your laptop\n".write(
            to: source, atomically: true, encoding: .utf8)
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "es"))
            if status == .installed {
                let result = try await space.run(
                    "ai.translate", [source], ["target": .text("es"), "format": .text("md")])
                let text = try String(contentsOf: try result.url())
                #expect(text.hasPrefix("# "))
                #expect(!text.contains("The meeting starts at noon"))
                #expect(text.contains("- "))
            } else {
                do {
                    _ = try await space.run("ai.translate", [source], ["target": .text("es")])
                    Issue.record("translation should need a language download")
                } catch let error as StudioError {
                    guard case let .unavailable(message) = error else {
                        Issue.record("unexpected error \(error)")
                        return
                    }
                    #expect(
                        message.contains("Translation Languages")
                            || message.contains("cannot translate"))
                }
            }
            return
        }
        #endif
        await #expect(throws: StudioError.self) {
            try await space.run("ai.translate", [source], ["target": .text("es")])
        }
    }

    @Test func translateRefusesSameLanguage() async throws {
        let space = try Workspace()
        let source = space.url("note.md")
        try "The meeting starts at noon and everyone should bring a laptop.".write(
            to: source, atomically: true, encoding: .utf8)
        await #expect(throws: StudioError.self) {
            try await space.run("ai.translate", [source], ["target": .text("en")])
        }
        #expect(
            try StudioTranslator.detectLanguage(
                "La reunión empieza al mediodía y todos traen su portátil.") == "es")
    }

    @Test func translatedBlocksBecomeWordParagraphsAndTables() {
        let blocks = [
            DocumentMarkdown.Block(
                text: "Título", markdown: "Título", heading: 1, listLevel: 0, ordered: false),
            DocumentMarkdown.Block(
                text: "| A | B |\n| --- | --- |\n| 1 | 2 |",
                markdown: "| A | B |\n| --- | --- |\n| 1 | 2 |",
                heading: nil, listLevel: 0, ordered: false),
        ]
        let docx = IntelligenceSource.docxBlocks(blocks)
        #expect(docx.count == 2)
        if case let .table(rows) = docx[1] {
            #expect(rows == [["A", "B"], ["1", "2"]])
        } else {
            Issue.record("expected a table")
        }
    }
}
