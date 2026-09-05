import Darwin
import Foundation
import Testing

@testable import EdithKit

@Suite struct LighthouseReportTests {
    @Test func realReportAcceptsScoresAndRejectsInvalidRanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(
            #"{"categories":{"performance":{"score":0.875},"accessibility":{"score":1},"best-practices":{"score":-1},"seo":{"score":1e300}}}"#
                .utf8
        ).write(to: url)
        let scores = try LighthouseAuditor.scores(fromReport: url)
        #expect(scores.performance == 88)
        #expect(scores.accessibility == 100)
        #expect(scores.bestPractices == nil)
        #expect(scores.seo == nil)
    }

    @Test func oversizedAndSpecialReportsAreRefusedBeforeReading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 17 * 1_024 * 1_024)
        try file.close()
        #expect(throws: UsageDataFileError.self) {
            try LighthouseAuditor.scores(fromReport: url)
        }
        try FileManager.default.removeItem(at: url)
        #expect(mkfifo(url.path, 0o600) == 0)
        #expect(throws: UsageDataFileError.self) {
            try LighthouseAuditor.scores(fromReport: url)
        }
    }
}
