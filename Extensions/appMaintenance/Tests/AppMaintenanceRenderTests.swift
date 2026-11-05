import AppKit
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import AppMaintenanceExtension

@MainActor
struct AppMaintenanceRenderFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let applications: [InstalledApplication]
    let updates: [AppUpdateItem]

    static let names = [
        ("Calculator", "/System/Applications/Calculator.app", "Mac App Store"),
        ("Notes", "/System/Applications/Notes.app", "Homebrew"),
        ("Mail", "/System/Applications/Mail.app", "Sparkle"),
        ("Calendar", "/System/Applications/Calendar.app", "Mac App Store"),
        ("Preview", "/System/Applications/Preview.app", "Homebrew"),
    ]

    init(updates withUpdates: Bool, history: Bool) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic.maintenance.render.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "synthetic.maintenance.render." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        let checked = Date(timeIntervalSince1970: 1_793_000_000)
        applications = Self.names.enumerated().map { index, entry in
            InstalledApplication(
                id: entry.1, name: entry.0, bundleID: "com.synthetic.\(entry.0.lowercased())",
                version: "\(index + 2).\(index).0", url: URL(fileURLWithPath: entry.1),
                update: withUpdates && index < 3
                    ? AppMaintenanceUpdate(
                        source: entry.2, installedVersion: "\(index + 2).\(index).0",
                        latestVersion: "\(index + 2).\(index + 1).0")
                    : nil)
        }
        let sources = AppUpdateSource.allCases
        updates =
            withUpdates
            ? Self.names.prefix(3).enumerated().map { index, entry in
                AppUpdateItem(
                    id: "synthetic:\(index)", name: entry.0,
                    bundleID: "com.synthetic.\(entry.0.lowercased())", applicationPath: entry.1,
                    source: sources[index % sources.count],
                    currentVersion: "\(index + 2).\(index).0",
                    availableVersion: "\(index + 2).\(index + 1).0",
                    releaseTitle: "Version \(index + 2).\(index + 1)",
                    releaseNotes: "Faster search, a refreshed sidebar and several fixes.",
                    confidence: .high, checkedAt: checked, action: .install,
                    executablePath: "/synthetic/never-execute",
                    arguments: ["upgrade", entry.0.lowercased()])
            } : []
        let results =
            history
            ? Self.names.enumerated().map { index, entry in
                AppUpdateResult(
                    itemID: "synthetic:\(index)", name: entry.0,
                    source: sources[index % sources.count], version: "\(index + 2).\(index + 1).0",
                    status: index == 2 ? .failed : .succeeded, attempts: 1,
                    detail: index == 2 ? "The download could not be verified." : "Updated",
                    finishedAt: checked.addingTimeInterval(Double(-index) * 3_600))
            } : []
        try persistence.save(AppUpdateCenterState(history: results))
    }

    var persistence: AppUpdatePersistence {
        AppUpdatePersistence(fileURL: root.appendingPathComponent("state.json"))
    }

    func model(holdInventory: Bool = false) -> AppMaintenanceModel {
        let applications = applications
        let updates = updates
        return AppMaintenanceModel(
            defaults: defaults, persistence: persistence,
            snapshots: AppMaintenanceSnapshotStore(
                fileURL: root.appendingPathComponent("snapshot.json")),
            inventory: { _ in
                if holdInventory { try? await Task.sleep(for: .seconds(30)) }
                return applications
            },
            now: { Date(timeIntervalSince1970: 1_793_000_000) },
            discover: { _, _, _, _ in updates })
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Suite(.serialized)
struct AppMaintenanceRenderTests {
    static func ready(_ model: AppMaintenanceModel) async {
        model.refresh(interval: 86_400)
        for _ in 0..<300 where model.phase != .ready || model.checkingUpdates {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    static func capture(
        _ name: String, model: AppMaintenanceModel, section: AppMaintenanceSection
    ) async throws {
        for variant in AppMaintenanceRenderCapture.variants {
            _ = try await AppMaintenanceRenderCapture.render(name, variant: variant) {
                AppMaintenanceView(model: model, section: section)
            }
        }
    }

    @Test func updatesListShowsEachAvailableUpdate() async throws {
        let fixture = try AppMaintenanceRenderFixture(updates: true, history: true)
        defer { fixture.remove() }
        let model = fixture.model()
        await Self.ready(model)
        #expect(model.updates.count == 3)
        try await Self.capture("maintenance-updates", model: model, section: .updates)
        await model.shutdown()
    }

    @Test func upToDateIsACalmEmptyState() async throws {
        let fixture = try AppMaintenanceRenderFixture(updates: false, history: false)
        defer { fixture.remove() }
        let model = fixture.model()
        await Self.ready(model)
        #expect(model.updates.isEmpty)
        try await Self.capture("maintenance-up-to-date", model: model, section: .updates)
        await model.shutdown()
    }

    @Test func loadingShowsASkeleton() async throws {
        let fixture = try AppMaintenanceRenderFixture(updates: true, history: false)
        defer { fixture.remove() }
        let model = fixture.model(holdInventory: true)
        model.refresh(interval: 86_400)
        #expect(model.phase == .loading)
        try await Self.capture("maintenance-loading", model: model, section: .updates)
        await model.shutdown()
    }

    @Test func removalListsInstalledApps() async throws {
        let fixture = try AppMaintenanceRenderFixture(updates: true, history: false)
        defer { fixture.remove() }
        let model = fixture.model()
        await Self.ready(model)
        #expect(model.applications.count == 5)
        try await Self.capture("maintenance-removal", model: model, section: .removal)
        await model.shutdown()
    }

    @Test func historyListsFinishedUpdates() async throws {
        let fixture = try AppMaintenanceRenderFixture(updates: false, history: true)
        defer { fixture.remove() }
        let model = fixture.model()
        await Self.ready(model)
        try await Self.capture("maintenance-history", model: model, section: .history)
        await model.shutdown()
    }
}
