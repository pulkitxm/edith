import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import SystemExtension

enum SystemRenderFixture {
    static let apps = [
        RunningAppSnapshot(
            pid: 90_001, name: "Safari", bundleID: "com.synthetic.browser", active: true),
        RunningAppSnapshot(
            pid: 90_002, name: "Xcode", bundleID: "com.synthetic.ide", active: false),
        RunningAppSnapshot(
            pid: 90_003, name: "Music", bundleID: "com.synthetic.music", active: false),
        RunningAppSnapshot(
            pid: 90_004, name: "Notes", bundleID: "com.synthetic.notes", active: false),
        RunningAppSnapshot(
            pid: 90_005, name: "Finder", bundleID: "com.apple.finder", active: false),
        RunningAppSnapshot(
            pid: 90_006, name: "Preview", bundleID: "com.synthetic.preview", active: false),
    ]

    static let memory: [pid_t: Double] = [
        90_001: 1_840, 90_002: 3_620, 90_003: 412, 90_004: 188, 90_005: 96, 90_006: 140,
    ]

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var ticks: [pid_t: UInt64] = [:]

        func sample(_ pid: pid_t) -> RunningAppResourceSample {
            lock.withLock {
                let step = UInt64(pid % 7 + 1) * 300_000
                ticks[pid, default: 0] += step
                return RunningAppResourceSample(
                    cpuNanoseconds: ticks[pid] ?? 0, memoryMB: memory[pid] ?? 120)
            }
        }
    }

    static func operations(_ apps: [RunningAppSnapshot]) -> RunningAppOperationCenter {
        let clock = Clock()
        return RunningAppOperationCenter(
            snapshot: { apps }, perform: { _, _ in 0 }, resource: { clock.sample($0) })
    }
}

@MainActor
@Suite(.serialized)
struct SystemPageRenderTests {
    static func model(_ apps: [RunningAppSnapshot]) throws -> RunningAppsModel {
        let defaults = try #require(
            UserDefaults(suiteName: "synthetic.system.render." + UUID().uuidString))
        return RunningAppsModel(
            operations: SystemRenderFixture.operations(apps), defaults: defaults)
    }

    static func capture(_ name: String, model: RunningAppsModel) async throws {
        let presentation = SystemPresentationState(channel: nil)
        for variant in SystemRenderCapture.variants {
            _ = try await SystemRenderCapture.render(name, variant: variant) {
                SystemPage(model: model, presentation: presentation)
            }
        }
    }

    @Test func runningAppsListUsageAndQuitActions() async throws {
        let model = try Self.model(SystemRenderFixture.apps)
        await model.refresh()
        await model.refresh()
        #expect(model.apps.count == SystemRenderFixture.apps.count)
        #expect(model.quitAllTargetCount == SystemRenderFixture.apps.count - 1)
        try await Self.capture("system-apps", model: model)
        model.shutdown()
    }

    @Test func loadingShowsASkeleton() async throws {
        let model = try Self.model(SystemRenderFixture.apps)
        _ = model.loading.begin()
        #expect(model.apps.isEmpty)
        try await Self.capture("system-loading", model: model)
        model.shutdown()
    }

    @Test func noMatchesOffersToClearTheSearch() async throws {
        let model = try Self.model(SystemRenderFixture.apps)
        await model.refresh()
        model.query = "photoshop"
        #expect(model.visibleApps.isEmpty)
        try await Self.capture("system-no-matches", model: model)
        model.shutdown()
    }

    @Test func protectedQuitShowsAnExplainedStatus() async throws {
        let model = try Self.model(SystemRenderFixture.apps)
        await model.refresh()
        let finder = try #require(model.apps.first { $0.bundleID == "com.apple.finder" })
        model.quit(finder)
        #expect(model.actionStatus != nil)
        try await Self.capture("system-status", model: model)
        model.shutdown()
    }
}
