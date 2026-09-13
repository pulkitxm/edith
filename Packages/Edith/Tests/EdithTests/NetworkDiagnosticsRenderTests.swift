import AppKit
import SwiftUI
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite @MainActor struct NetworkDiagnosticsRenderTests {
    @Test func successfulSnapshotRendersInTheMenuPanel() throws {
        let snapshot = NetworkDiagnosticSnapshot(
            createdAt: Date(timeIntervalSince1970: 1_783_080_000), durationMS: 124,
            state: .healthy, path: NetworkPathSummary(),
            checks: [
                NetworkDiagnosticCheck(
                    id: "route", title: "Route", state: .healthy, summary: "Available"),
                NetworkDiagnosticCheck(
                    id: "dns", title: "DNS", state: .healthy, summary: "Resolved"),
                NetworkDiagnosticCheck(
                    id: "gateway", title: "Gateway", state: .healthy, summary: "Reachable"),
            ])
        let hosting = NSHostingView(
            rootView:
                NetworkDiagnosticsPanel(snapshot: snapshot, openWorkspace: {})
                .padding(20).frame(width: 460, height: 245)
                .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 245)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 460)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent(
                    "network-diagnostics.png"))
        }
    }
}
