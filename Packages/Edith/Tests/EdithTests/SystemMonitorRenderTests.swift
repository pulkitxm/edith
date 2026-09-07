import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@Suite @MainActor struct SystemMonitorRenderTests {
    @Test func settingsRenderWithSharedMetricsControls() throws {
        let snapshot = SystemMonitorSnapshot(
            sampledAt: 100, cpuPercent: 23, memoryPercent: 42, gpuPercent: 12,
            network: .init(inboundBytesPerSecond: 2_400_000, outboundBytesPerSecond: 340_000),
            disk: .init(inboundBytesPerSecond: 18_000_000, outboundBytesPerSecond: 4_000_000),
            rootDiskUsedPercent: 36,
            battery: .init(percent: 82, isCharging: true, externalPower: true, watts: 12))
        let hosting = NSHostingView(
            rootView:
                SystemMonitorSummary(monitorSnapshot: snapshot, dark: true)
                .padding(20).frame(width: 580, height: 400)
                .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(x: 0, y: 0, width: 580, height: 400)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 580)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("system-monitor.png"))
        }
    }
}
