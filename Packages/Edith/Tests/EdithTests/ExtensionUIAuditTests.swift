import AppKit
import EdithDatabase
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit
@testable import EdithHelper

@MainActor @Suite(.serialized)
struct ExtensionUIAuditTests {
    @Test func usage() throws { try render("usage") }
    @Test func herdr() throws { try render("herdr") }
    @Test func quinjet() throws { try render("quinjet") }
    @Test func companion() throws { try render("companion") }
    @Test func plugins() throws { try render("plugins") }
    @Test func appMaintenance() throws { try render("appMaintenance") }
    @Test func homebrew() throws { try render("homebrew") }
    @Test func cleaner() throws { try render("cleaner") }
    @Test func blitztree() throws { try render("blitztree") }
    @Test func system() throws { try render("system") }
    @Test func keepAwake() throws { try render("keepAwake") }
    @Test func lidAwake() throws { try render("lidAwake") }
    @Test func systemStats() throws { try render("systemStats") }
    @Test func micMute() throws { try render("micMute") }
    @Test func bifrost() throws { try render("bifrost") }
    @Test func clipboard() throws { try render("clipboard") }
    @Test func emoji() throws { try render("emoji") }
    @Test func colorPicker() throws { try render("colorPicker") }
    @Test func keystrokeHighlight() throws { try render("keystrokeHighlight") }
    @Test func focusDim() throws { try render("focusDim") }
    @Test func windowSweaters() throws { try render("windowSweaters") }
    @Test func presenter() throws { try render("presenter") }
    @Test func studio() throws { try render("studio") }
    @Test func music() throws { try render("music") }
    @Test func downloads() throws { try render("downloads") }
    @Test func notchShelf() throws { try render("notchShelf") }
    @Test func audioMixer() throws {
        try render("audioMixer")
        guard #available(macOS 14.4, *) else { return }
        var fails = true
        let engine = MixerEngine(snapshotLoader: {
            if fails { throw AudioMixerDiscoveryError.processList(-50) }
            return AudioMixerSnapshot(apps: [], outputUID: "sample-output")
        })
        defer { engine.shutdown() }
        engine.refresh()
        let host = try auditHost(
            AudioMixerView(engine: engine, monitorsWhileVisible: false),
            size: CGSize(width: 450, height: 220))
        let text = try auditText(host)
        #expect(text.contains("could not be refreshed"))
        #expect(text.contains("Retry"))
        #expect(!text.contains("Play audio"))
        fails = false
        engine.retry()
        host.layoutSubtreeIfNeeded()
        #expect(try auditText(host).contains("Play audio"))
    }
    @Test func calendar() throws { try render("calendar") }
    @Test func virtualCamera() throws { try render("virtualCamera") }
    @Test func database() async throws {
        try render("database")
        let model = DatabasePageModel(
            ensureReady: { throw DatabaseBrokerAvailabilityError.readinessTimedOut },
            repairService: {}, preparePack: { _ in })
        let workspace = DatabaseConnectionWorkspaceModel(
            sender: AuditDatabaseSender(), announcement: { _ in })
        await model.refresh()
        let host = try auditHost(
            DatabasePage(model: model, connectionWorkspace: workspace),
            size: CGSize(width: 1100, height: 700))
        #expect(try auditText(host).contains("Database needs a quick repair"))
        await model.repair()
        await workspace.loadConnections()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let text = try auditText(host)
        #expect(text.contains("Connections"))
        #expect(text.contains("Add connection"))
        #expect(!text.contains("Database needs a quick repair"))
        try auditCapture(host, name: "database-ready")
    }
    @Test func attention() async throws {
        try render("attention")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "activity-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AttentionRepository(root: root)
        for (index, fixture) in [
            ("Sample Notes", "com.apple.Notes"), ("Sample Video", "test.video"),
            ("Sample Comedy", "test.comedy"),
        ].enumerated() {
            try repository.append(
                AttentionEvent(
                    startedAt: Date().addingTimeInterval(-Double((index + 1) * 120)), duration: 60,
                    source: .application, appName: fixture.0, bundleID: fixture.1))
        }
        let model = AttentionPageModel(repository: repository)
        model.section = .breakdown
        model.reload()
        await model.waitForReload()
        #expect(model.summary.entities.count == 3)
        _ = await AttentionApplicationIcon.resolve(bundleID: "com.apple.Notes")
        let host = try auditHost(
            AttentionBreakdownView(model: model).padding(24), size: CGSize(width: 1150, height: 680)
        )
        let text = try auditText(host)
        #expect(text.contains("Sample Notes"))
        #expect(text.contains("Sample Video"))
        #expect(text.uppercased().contains("TIME"))
        #expect(text.uppercased().contains("SHARE"))
        try auditCapture(host, name: "attention-activity")
    }
    @Test func seoAudit() throws { try render("seoAudit") }
    @Test func codeStats() throws { try render("codeStats") }
    @Test func codeStatsPage() async throws {
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(
                storage: .volumeDisconnected(volumeName: "Archive"),
                reportedAt: CodeStatsPageFixture.date("2026-10-01"), github: .signedOut),
            reports: [.days(90): CodeStatsPageFixture.report()])
        let model = CodeStatsModel(
            service: agent.service,
            defaults: UserDefaults(suiteName: "test.edith.code-stats-audit.\(UUID())")!,
            calendar: CodeStatsPageFixture.calendar)
        await model.refresh()
        let host = try auditHost(
            CodeStatsPage(model: model), size: CGSize(width: 1150, height: 1300))
        let text = try auditText(host)
        #expect(text.contains("Archive is disconnected"))
        #expect(text.contains("gh auth login"))
        #expect(text.uppercased().contains("COMMITS"))
        #expect(text.contains("Contributions"))
        try auditCapture(host, name: "code-stats-disconnected")
    }

    private func render(_ id: String) throws {
        let entry = try #require(ExtensionRegistry.entry(id))
        let defaults = SharedDefaults.store
        let previous = defaults.object(forKey: entry.defaultsKey)
        defaults.set(true, forKey: entry.defaultsKey)
        defer { defaults.set(previous, forKey: entry.defaultsKey) }
        let host = try auditHost(
            Form { ExtensionDetailRows(entry: entry) }.formStyle(.grouped),
            size: CGSize(width: 900, height: 1000))
        let text = try auditText(host)
        #expect(!text.isEmpty, "Controls must render for \(id)")
        #expect(!text.contains("No extension controls are registered"))
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }
}

private struct AuditDatabaseSender: DatabaseBrokerCommandSending {
    func send(_ request: DatabaseBrokerCommandRequest) async throws -> DatabaseBrokerCommandResponse
    {
        .connectionList(
            .success(
                DatabaseConnectionListResult(connections: []),
                metadata: DatabaseResultMetadata(
                    completeness: DatabaseResultCompleteness(state: .complete))))
    }
}

@MainActor
private func auditCapture(_ host: NSHostingView<AnyView>, name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["EDITH_EXTENSION_EVIDENCE_DIR"] else {
        return
    }
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try png.write(to: root.appendingPathComponent("\(name).png"))
}
