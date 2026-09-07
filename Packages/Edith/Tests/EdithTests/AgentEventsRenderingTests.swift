import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct AgentEventsRenderingTests {
    @Test func timelineRendersSyntheticEventsAndLoadingStates() throws {
        let model = AgentEventsModel()
        let anchor = Date(timeIntervalSince1970: 1_783_512_000)
        model.receive(
            (0..<150).map { index in
                AgentEvent(
                    date: anchor.addingTimeInterval(Double(index) * 15),
                    level: index.isMultiple(of: 7) ? .warning : .info,
                    category: "sample.jobs",
                    name: index.isMultiple(of: 7) ? "job.deferred" : "job.completed",
                    message: index.isMultiple(of: 7)
                        ? "Sample archive refresh will resume when external power is available."
                        : "Sample workspace inventory refreshed successfully.",
                    duration: index.isMultiple(of: 7) ? nil : 0.24)
            })
        try render(AgentEventsScreen(model: model), name: "agent-events")
        try render(AgentEventsScreen(), name: "agent-events-loading")
        model.filter(search: "missing", errorsOnly: true)
        try render(AgentEventsScreen(model: model), name: "agent-events-empty")
        try render(BackgroundAgentPane(), name: "agent-settings-loading")
    }

    private func render(_ view: some View, name: String) throws {
        let host = NSHostingView(
            rootView:
                view
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 840, height: 620)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        #expect(bitmap.pixelsHigh > 0)
        if let directory = ProcessInfo.processInfo.environment["EDITH_EVIDENCE_DIR"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: destination.appendingPathComponent("\(name).png"))
        }
    }
}
