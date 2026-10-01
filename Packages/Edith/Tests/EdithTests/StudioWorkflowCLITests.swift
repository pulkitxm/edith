import EdithStudio
import Foundation
import Testing

@testable import EdithCLI

@Suite struct StudioWorkflowCLITests {
    @Test func aWorkflowFileRoundTripsOutsideTheRealLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workflow = StudioWorkflow(
            name: "Synthetic", steps: [StudioWorkflow.Step(toolID: "pdf.ocr")])
        try StudioWorkflowFile.save([workflow], to: directory)
        #expect(StudioWorkflowFile.load(from: directory) == [workflow])
    }

    @Test func settingsAttachToTheNamedStep() throws {
        let steps = try StudioWorkflowCLI.steps(
            ["pdf.ocr", "pdf.compress"], settings: ["pdf.ocr:accuracy=fast"])
        #expect(steps.map(\.toolID) == ["pdf.ocr", "pdf.compress"])
        #expect(steps[0].settings.text("accuracy") == "fast")
    }

    @Test func helpShowsTheRecordingAndWorkflowExamples() {
        #expect(
            StudioRecordStartCommand.helpMessage(columns: 220).contains(
                "ed studio record start --display 1 --json"))
        #expect(
            StudioWorkflowRemoveCommand.helpMessage(columns: 220).contains(
                "ed studio workflow rm"))
    }
}
