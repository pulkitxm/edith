import AppKit
import EdithExtensionFiles
import EdithExtensionSupport
import Foundation
import SwiftUI
import Testing

@testable import HerdrUI

@MainActor
@Suite(.serialized) struct HerdrFilesPaneObservationTests {
    init() {
        _ = TestWindowHost.application
    }

    private func agent(cwd: String) -> HerdrAgent {
        HerdrAgent(
            id: "files-pane-\(UUID().uuidString)", machineID: Machine.localID.uuidString,
            machineName: "This Mac", machineIsLocal: true, sshTarget: nil, session: "default",
            pane: "a", kind: "claude", status: .idle, title: "Local agent", workspace: "",
            cwd: cwd)
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-files-pane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("alpha.txt"))
        try Data("b".utf8).write(to: root.appendingPathComponent("beta.txt"))
        return root
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(condition())
    }

    @Test func theFilesViewShowsTheFinderForTheAgentsFolder() async throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = agent(cwd: folder.path)
        let suite = "HerdrFilesPaneObservation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tab = HerdrOpenTab(
            agent: agent, machine: nil, view: .files, holder: TerminalSessionHolder(),
            quinjet: HerdrQuinjetSession(),
            files: HerdrFilesSession { HerdrStore.directFilesSession(for: $0) },
            split: HerdrSplitCompanionState(agentID: agent.id, defaults: defaults))
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in })

        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600))
        let hosting = NSHostingView(
            rootView: HerdrSessionView(
                store: store, tab: tab, launchEnabled: false, showsDetails: false))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = hosting

        try await eventually { tab.files.finder?.path == folder.path }
        try await eventually {
            Set(tab.files.finder?.entries.map(\.name) ?? []) == ["alpha.txt", "beta.txt"]
        }
        #expect(tab.showsFiles)
        #expect(!tab.showsDiff)

        window.contentView = nil
        tab.files.discard()
    }

    @Test func theSplitShowsTheFilesOnlyAfterTheyAreChosen() async throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = agent(cwd: folder.path)
        let suite = "HerdrFilesPaneObservation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let split = HerdrSplitCompanionState(agentID: agent.id, defaults: defaults)
        let tab = HerdrOpenTab(
            agent: agent, machine: nil, view: .split, holder: TerminalSessionHolder(),
            quinjet: HerdrQuinjetSession(),
            files: HerdrFilesSession { HerdrStore.directFilesSession(for: $0) }, split: split)
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in })

        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600))
        let hosting = NSHostingView(
            rootView: HerdrSessionView(
                store: store, tab: tab, launchEnabled: false, showsDetails: false))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = hosting
        try await Task.sleep(for: .milliseconds(300))
        #expect(tab.files.finder == nil)

        split.select(.files)
        try await eventually { tab.files.finder?.path == folder.path }
        #expect(tab.showsFiles)
        #expect(!tab.showsDiff)

        window.contentView = nil
        tab.files.discard()
    }
}
