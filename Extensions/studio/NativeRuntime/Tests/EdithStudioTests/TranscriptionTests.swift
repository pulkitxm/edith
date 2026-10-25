import Foundation
import Testing

@testable import EdithStudio

@Suite struct TranscriptionTests {
    let words: [StudioTranscription.Word] = [
        .init(text: "Hello", start: 0.2, end: 0.5), .init(text: "there.", start: 0.6, end: 0.9),
        .init(text: "This", start: 2.5, end: 2.7), .init(text: "is", start: 2.8, end: 2.9),
        .init(text: "Studio", start: 3.0, end: 3.4),
    ]

    @Test func cuesBreakOnSentencesAndPauses() {
        let cues = StudioTranscription.cues(from: words)
        #expect(cues.map(\.text) == ["Hello there.", "This is Studio"])
        #expect(cues[0].start == 0.2)
        let srt = StudioTranscription.srt(cues)
        #expect(srt.hasPrefix("1\n00:00:00,200 --> 00:00:00,900\nHello there.\n"))
        #expect(srt.contains("2\n00:00:02,500 --> 00:00:03,400\nThis is Studio"))
        let vtt = StudioTranscription.vtt(cues)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.200 --> 00:00:00.900"))
        #expect(StudioTranscription.plain(words) == "Hello there.\n\nThis is Studio\n")
    }

    @Test func longRunsSplitByLength() {
        let long = (0..<20).map {
            StudioTranscription.Word(
                text: "w\($0)", start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25)
        }
        let cues = StudioTranscription.cues(from: long)
        #expect(cues.count >= 3)
        #expect(cues.allSatisfy { $0.text.split(separator: " ").count <= 8 })
    }

    @Test func toolExplainsWhereItRunsWithoutAPermissionString() async throws {
        let space = try Workspace()
        let audio = space.url("voice.m4a")
        try Data().write(to: audio)
        #expect(!StudioTranscription.canAskForPermission)
        await #expect(throws: StudioError.self) { try await space.run("ai.transcribe", [audio]) }
    }
}
