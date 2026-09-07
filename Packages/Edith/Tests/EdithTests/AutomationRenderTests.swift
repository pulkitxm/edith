import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EdithAgent
@testable import EdithHelper
@testable import EdithKit

@Suite @MainActor struct AutomationRenderTests {
    @Test func scenesRenderAfterAgentExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AutomationStorage(root: root)
        let scene = AutomationScene(
            name: "Start the workday", actions: [AutomationAction(operationID: "app.info")])
        let evening = AutomationScene(
            name: "Evening reset", actions: [AutomationAction(operationID: "app.info")])
        try storage.save(AutomationDocument(scenes: [scene, evening]))
        let service = AutomationService(
            storage: storage, isEnabled: { true }, runner: { _ in "Ready" })
        let result = try await service.execute(
            AgentAutomationRunRequest(sceneID: scene.id, origin: .menuPanel))
        #expect(result.succeeded)
        let runtime = AutomationRuntime(storage: storage)
        defer { runtime.shutdown() }
        let view = ZStack {
            Color(nsColor: .windowBackgroundColor)
            AutomationView(runtime: runtime).padding(20)
        }.frame(width: 500, height: 330)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 330)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(runtime.history.last?.succeeded == true)
        #expect(bitmap.pixelsWide >= 500)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("automations-scenes.png")
            )
        }
    }
}
