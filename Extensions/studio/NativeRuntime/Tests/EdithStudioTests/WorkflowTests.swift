import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct WorkflowTests {
    @Test func presetsAreValid() throws {
        for preset in StudioWorkflow.presets {
            try preset.validate()
            #expect(preset.tool != nil)
            #expect(!preset.summary.isEmpty)
        }
    }

    @Test func photoWorkflowRunsEveryStepOnEveryFile() async throws {
        let space = try Workspace()
        let first = space.url("one.jpg")
        let second = space.url("two.jpg")
        try Fixtures.image(at: first, width: 3000, height: 2000, format: .jpeg)
        try Fixtures.image(at: second, width: 2400, height: 3200, format: .jpeg)
        let workflow = try #require(
            StudioWorkflow.presets.first { $0.name == "Photos ready for the web" })
        let tool = try #require(workflow.tool)
        let result = try await StudioRunner.run(
            tool: tool, inputs: [first, second], destination: .folder(space.output),
            environment: space.environment)
        #expect(result.outputs.count == 2)
        for output in result.outputs {
            let info = try #require(StudioImageIO.info(output.url))
            #expect(max(info.width, info.height) == 2048)
            #expect(
                output.url.deletingLastPathComponent().standardizedFileURL
                    == space.output.standardizedFileURL)
        }
    }

    @Test func pdfWorkflowMergesThenNumbers() async throws {
        let space = try Workspace()
        let a = space.url("a.pdf")
        let b = space.url("b.pdf")
        try Fixtures.pdf(at: a, pages: ["Alpha"])
        try Fixtures.pdf(at: b, pages: ["Beta", "Gamma"])
        let workflow = StudioWorkflow(
            name: "Bundle",
            steps: [
                .init(toolID: "pdf.merge"),
                .init(
                    toolID: "pdf.page-numbers",
                    settings: StudioSettings(["format": .text("Page {n} of {total}")])),
            ])
        let result = try await StudioRunner.run(
            tool: try #require(workflow.tool), inputs: [a, b], destination: .folder(space.output),
            environment: space.environment)
        let document = try result.document()
        #expect(document.pageCount == 3)
        #expect(document.page(at: 2)?.string?.contains("Page 3 of 3") == true)
    }

    @Test func invalidChainsAreRejected() throws {
        let mismatched = StudioWorkflow(
            name: "Nope", steps: [.init(toolID: "pdf.merge"), .init(toolID: "image.resize")])
        #expect(throws: StudioError.self) { try mismatched.validate() }
        let missingPassword = StudioWorkflow(name: "Lock", steps: [.init(toolID: "pdf.protect")])
        #expect(throws: StudioError.self) { try missingPassword.validate() }
        let unnamed = StudioWorkflow(name: " ", steps: [.init(toolID: "pdf.compress")])
        #expect(throws: StudioError.self) { try unnamed.validate() }
        #expect(throws: StudioError.self) {
            try StudioWorkflow(name: "Empty", steps: []).validate()
        }
        let editor = StudioWorkflow(name: "Editor", steps: [.init(toolID: "pdf.edit")])
        #expect(throws: StudioError.self) { try editor.validate() }
    }

    @Test func candidatesFollowWhatEachStepProduces() throws {
        let workflow = StudioWorkflow(name: "x", steps: [.init(toolID: "pdf.to-images")])
        let next = workflow.candidates(after: 0).map(\.id)
        #expect(next.contains("image.compress"))
        #expect(next.contains("pdf.from-images"))
        #expect(!next.contains("pdf.compress"))
        #expect(!next.contains("pdf.edit"))
        let data = try JSONEncoder().encode(workflow)
        #expect(try JSONDecoder().decode(StudioWorkflow.self, from: data) == workflow)
    }
}
