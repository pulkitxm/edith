import AppKit
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import AppMaintenanceExtension

@Suite(.serialized) @MainActor struct MaintenanceScrollBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil

    @Test(.enabled(if: enabled)) func scrollingEverySectionWithSyntheticLibrary() async throws {
        let only = ProcessInfo.processInfo.environment["EDITH_SCROLL_CASE"]
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        for section in [AppMaintenanceSection.updates, .history, .removal]
        where only == nil || only == section.rawValue {
            let timing = try await Self.measure(
                section: section, applications: 1500, updates: 1500, history: 3000, frames: frames)
            print(
                "maintenance-scroll \(section.rawValue): \(timing) reach=\(Int(timing.offsets.max() ?? 0)) slowAt=\(timing.slowOffsets)"
            )
        }
    }

    @Test func scrollingStaysSmoothWithSyntheticLibrary() async throws {
        for section in [AppMaintenanceSection.updates, .history, .removal] {
            let timing = try await Self.measure(
                section: section, applications: 400, updates: 400, history: 400, frames: 60)
            print("maintenance-regression \(section.rawValue): \(timing)")
            #expect(timing.frames.count == 60)
            #expect(timing.worst < 100)
            #expect(timing.median < 12)
        }
    }

    static func measure(
        section: AppMaintenanceSection, applications: Int, updates: Int, history: Int, frames: Int
    ) async throws -> ScrollTiming {
        let fixture = try MaintenanceScrollFixture(
            applications: applications, updates: updates, history: history)
        defer { fixture.remove() }
        let model = fixture.model()
        let (window, host) = ScrollHarness.host(
            AppMaintenanceView(model: model, section: section)
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark),
            size: CGSize(width: 1100, height: 760))
        for _ in 0..<200 where model.checkingUpdates || model.phase != .ready {
            await ScrollHarness.settle(host, for: .milliseconds(50))
        }
        await ScrollHarness.settle(host, for: .seconds(1))
        let timing = await ScrollHarness.scroll(host, frames: frames)
        await ScrollHarness.settle(host)
        window.orderOut(nil)
        window.contentView = nil
        await model.shutdown()
        return timing
    }
}

@MainActor
struct MaintenanceScrollFixture {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let applications: [InstalledApplication]
    let updates: [AppUpdateItem]

    static let systemApplications = [
        "/System/Applications/Calculator.app", "/System/Applications/Notes.app",
        "/System/Applications/Mail.app", "/System/Applications/Calendar.app",
        "/System/Applications/Preview.app",
    ]

    init(applications count: Int, updates updateCount: Int, history: Int) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-maintenance-scroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "maintenance-scroll-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        let checked = Date(timeIntervalSince1970: 1_700_000_000)
        applications = (0..<count).map { index in
            let path = Self.systemApplications[index % Self.systemApplications.count]
            return InstalledApplication(
                id: "\(path)#\(index)", name: "Sample Application \(index)",
                bundleID: "test.sample.app\(index)", version: "\(index % 9).\(index % 13).0",
                url: URL(fileURLWithPath: path),
                update: index.isMultiple(of: 5)
                    ? AppMaintenanceUpdate(
                        source: "Mac App Store", installedVersion: "1.0", latestVersion: "2.0")
                    : nil)
        }
        let sources = AppUpdateSource.allCases
        updates = (0..<updateCount).map { index in
            AppUpdateItem(
                id: "sample:\(index)", name: "Sample Update \(index)",
                bundleID: "test.sample.update\(index)",
                applicationPath: Self.systemApplications[index % Self.systemApplications.count],
                source: sources[index % sources.count], currentVersion: "1.\(index % 40)",
                availableVersion: "2.\(index % 40)", releaseTitle: "Release \(index)",
                releaseNotes: "Notes for release \(index)", confidence: .high, checkedAt: checked,
                action: .install, executablePath: "/synthetic/never-execute",
                arguments: ["upgrade", "sample\(index)"])
        }
        let results = (0..<history).map { index in
            AppUpdateResult(
                itemID: "sample:\(index)", name: "Sample Update \(index)",
                source: sources[index % sources.count], version: "2.\(index % 40)",
                status: index.isMultiple(of: 7) ? .failed : .succeeded, attempts: 1,
                detail: "Finished", finishedAt: checked.addingTimeInterval(Double(-index) * 60))
        }
        try persistence.save(AppUpdateCenterState(history: results))
    }

    var persistence: AppUpdatePersistence {
        AppUpdatePersistence(fileURL: root.appendingPathComponent("state.json"))
    }

    func model() -> AppMaintenanceModel {
        let applications = applications
        let updates = updates
        return AppMaintenanceModel(
            defaults: defaults, persistence: persistence,
            snapshots: AppMaintenanceSnapshotStore(
                fileURL: root.appendingPathComponent("snapshot.json")),
            inventory: { _ in applications },
            discover: { _, _, _, _ in updates })
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
