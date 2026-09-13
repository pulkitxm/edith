import AppKit
import SwiftUI
import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit
@testable import EdithHelper

@Suite(.serialized) struct AgentScratchpadOperationTests {
    @Test @MainActor func daemonOwnsTheNamedPadWorkflow() async throws {
        let previous = ScratchpadPaths.root
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ScratchpadPaths.root = root
        defer {
            ScratchpadPaths.root = previous
            try? FileManager.default.removeItem(at: root)
        }
        let runtime = AgentRuntime(build: "scratchpad-test", store: nil)
        await AgentScratchpadOperations.register(on: runtime)
        func perform(_ operation: ScratchpadOperation, _ request: ScratchpadRequest) async throws
            -> ScratchpadDocument
        {
            let response = try await runtime.perform(
                operation: operation.descriptor.id.rawValue, payload: AgentPayload.encode(request))
            return try AgentPayload.decode(ScratchpadDocument.self, from: response)
        }
        let created = try await perform(
            .create,
            ScratchpadRequest(
                text:
                    "# Launch checklist\n\n- Review the landing page\n- Test the sign-in flow\n- Share release notes\n\n**Launch window:** Friday, 10:30 AM",
                name: "Release"))
        #expect(created.selectedPad?.name == "Release")
        let renamed = try await perform(
            .rename, ScratchpadRequest(selector: "Release", name: "Launch"))
        #expect(renamed.selectedPad?.name == "Launch")
        let duplicated = try await perform(.duplicate, ScratchpadRequest(selector: "Launch"))
        #expect(duplicated.selectedPad?.name == "Launch copy")
        #expect(duplicated.selectedPad?.text.contains("Launch checklist") == true)
        let cleared = try await perform(.clear, ScratchpadRequest(selector: "Launch copy"))
        #expect(cleared.selectedPad?.text.isEmpty == true)
        let removed = try await perform(.remove, ScratchpadRequest(selector: "Launch copy"))
        #expect(removed.pads.count == 2)
        let reloaded = try await perform(.list, ScratchpadRequest())
        #expect(reloaded == removed)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            let model = ScratchpadStore(document: reloaded)
            model.previewing = true
            let hosting = NSHostingView(rootView: ScratchpadPanelView(store: model, dismiss: {}))
            hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("scratchpad.png"))
        }
    }
}
