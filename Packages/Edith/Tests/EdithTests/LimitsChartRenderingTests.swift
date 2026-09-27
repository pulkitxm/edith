import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@Suite(.serialized) @MainActor struct LimitsChartRenderingTests {
    @Test(arguments: [1, 12])
    func switchingProvidersRendersWithSparseAllowanceHistory(grokPoints: Int) async throws {
        try #require(ProcessInfo.processInfo.environment["EDITH_DATA_ROOT"] != nil)
        let savedHistory = try? Data(contentsOf: LimitsHistory.url)
        try? FileManager.default.removeItem(at: LimitsHistory.url)
        let defaults = SharedDefaults.store
        let key = AppStorageKeys.Limits.provider
        let saved = defaults.object(forKey: key)
        defer {
            if let saved {
                defaults.set(saved, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            if let savedHistory {
                try? savedHistory.write(to: LimitsHistory.url)
            } else {
                try? FileManager.default.removeItem(at: LimitsHistory.url)
            }
        }
        let now = Date()
        var history = LimitsHistory()
        for provider in LimitProvider.allCases {
            let count = provider == .grok ? grokPoints : 12
            for index in 0..<count {
                let written = history.append(
                    provider: provider,
                    session: provider == .grok
                        ? nil : LimitWindow(percent: Double(index * 5), resetsAt: nil),
                    week: LimitWindow(percent: Double(index * 3), resetsAt: nil),
                    now: now.addingTimeInterval(Double(index - count) * 3600))
                #expect(written)
            }
        }
        defaults.set(LimitProvider.claude.rawValue, forKey: key)
        let host = NSHostingView(
            rootView: VStack(spacing: 16) {
                RateLimitsDialsView(dark: true)
                LimitsCardView(theme: .orange, dark: true)
            }
            .padding(20)
            .environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 660))
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        for provider in [LimitProvider.claude, .grok, .cursor, .codex, .grok, .claude] {
            defaults.set(provider.rawValue, forKey: key)
            for frame in 0..<8 {
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsWide > 0)
                if frame == 7, grokPoints == 12,
                    let directory = ProcessInfo.processInfo.environment["EDITH_EVIDENCE_DIR"]
                {
                    let destination = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: destination, withIntermediateDirectories: true)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(
                        to: destination.appendingPathComponent("limits-\(provider.rawValue).png"))
                }
            }
        }
    }
}
