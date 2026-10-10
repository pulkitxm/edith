import Foundation
import Testing

@testable import EdithStudio

@Suite struct DocsAuditIntelligenceTests {
    @Test func summaryChunksNeverExceedTheLimit() {
        let text = "Short intro.\n" + String(repeating: "y", count: 1300) + "\nTail."
        let chunks = StudioSummarizer.chunks(text, limit: 500)
        #expect(chunks.allSatisfy { $0.count <= 500 })
        #expect(
            chunks.joined().replacingOccurrences(of: "\n", with: "")
                == text.replacingOccurrences(of: "\n", with: ""))
        #expect(chunks.first == "Short intro.")
    }

    @Test func aiToolsFailClearlyWhenUnavailable() async throws {
        let space = try Workspace()
        let source = space.url("note.md")
        try "The meeting starts at noon and everyone brings a laptop.".write(
            to: source, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: source)
        var environment = space.environment
        environment.appleIntelligenceAvailable = false
        do {
            _ = try await space.run("ai.summarize", [source], environment: environment)
            Issue.record("summarize ran without Apple Intelligence")
        } catch let error as StudioError {
            #expect(error.localizedDescription.contains("Apple Intelligence"))
        }
        let started = Date()
        do {
            let result = try await space.run(
                "ai.translate", [source], ["target": .text("th"), "format": .text("md")])
            #expect(try String(contentsOf: try result.url(), encoding: .utf8).isEmpty == false)
        } catch let error as StudioError {
            #expect(error.localizedDescription.isEmpty == false)
        }
        #expect(Date().timeIntervalSince(started) < 120)
        let audio = space.url("voice.m4a")
        try Data("not audio".utf8).write(to: audio)
        await #expect(throws: StudioError.self) { try await space.run("ai.transcribe", [audio]) }
        #expect(try Data(contentsOf: source) == original)
    }
}
