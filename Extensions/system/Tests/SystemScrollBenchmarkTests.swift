import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import SystemExtension

@Suite(.serialized) @MainActor struct SystemScrollBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil

    @Test(.enabled(if: enabled)) func scrollingAThousandRunningApps() async throws {
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        let timing = try await Self.measure(apps: 1_000, frames: frames)
        print("system-scroll running-apps: \(timing) slowAt=\(timing.slowOffsets)")
    }

    @Test func scrollingStaysSmoothWithManyRunningApps() async throws {
        let timing = try await Self.measure(apps: 300, frames: 60)
        print("system-regression running-apps: \(timing)")
        #expect(timing.frames.count == 60)
        #expect(timing.worst < 100)
        let budget = ProcessInfo.processInfo.environment["CI"] == nil ? 12.0 : 1000.0 / 60
        #expect(timing.median < budget)
    }

    static func measure(apps count: Int, frames: Int) async throws -> ScrollTiming {
        let suite = "system-scroll-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshots: [RunningAppSnapshot] = (0..<count).map {
            (index: Int) -> RunningAppSnapshot in
            let cpu: Double = Double(index % 40)
            let memory: Double = Double(50 + index * 7 % 900)
            return RunningAppSnapshot(
                pid: pid_t(1_000 + index), name: "Synthetic App \(index)",
                bundleID: "test.synthetic.app\(index)", active: false,
                cpuPercent: cpu, memoryMB: memory)
        }
        let operations = RunningAppOperationCenter(
            snapshot: { snapshots }, perform: { _, _ in 0 },
            resource: { _ in .init(cpuNanoseconds: 0, memoryMB: 120) })
        let model = RunningAppsModel(operations: operations, defaults: defaults)
        await model.refresh()
        #expect(model.apps.count == count)
        let presentation = SystemPresentationState(channel: nil)
        let (window, host) = ScrollHarness.host(
            SystemPage(model: model, presentation: presentation)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil },
            size: CGSize(width: 1120, height: 860))
        await ScrollHarness.settle(host, for: .seconds(1))
        let timing = await ScrollHarness.scroll(host, frames: frames)
        window.orderOut(nil)
        window.contentView = nil
        model.shutdown()
        return timing
    }
}
