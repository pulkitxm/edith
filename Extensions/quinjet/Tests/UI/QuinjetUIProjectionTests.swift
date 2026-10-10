import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import QuinjetUI

@MainActor @Suite(.serialized) struct QuinjetUIProjectionTests {
    @Test func originalReviewActionsUseOwnedEngineModelsAndRejectInjectedLaunchFields() async throws
    {
        defer { QuinjetWorkOwnership.enable() }
        let tree = QuinjetWorktree(
            path: "/private/tmp/synthetic", head: "1234567", branch: "fixture",
            current: true, bare: false, detached: false, locked: nil, prunable: nil)
        let project = QuinjetProject(
            name: "Synthetic review", commonDir: "/private/tmp/synthetic/.git",
            worktrees: [tree])
        let worker = QuinjetWorker(
            client: .init(execute: { arguments in
                if arguments == ["project", "list", "--json"] {
                    return try JSONEncoder().encode([project])
                }
                #expect(arguments == ["-C", tree.path, "worktree", "list", "--json"])
                return try JSONEncoder().encode([tree])
            }), automaticActions: false)
        let model = QuinjetPageModel(
            uiClient: .init {
                try await worker.execute($0, payload: $1)
            })
        await model.refreshProjects()
        #expect(model.projects == [project])
        #expect(model.selected == worker.model.selected)
        let original = try #require(model.selectedTab)
        await model.openFolder(tree.path, in: original, launchEnabled: true)
        #expect(model.selectedTab === original && original.worktree == tree)
        #expect(original.holder.terminalLaunch == nil && original.holder.descriptor == nil)
        #expect(worker.model.selectedTab?.worktree == tree)
        _ = try await model.performSessionOperation(.init(operation: .create))
        #expect(model.tabs.count == 2 && model.tabs.map(\.id) == worker.model.tabs.map(\.id))
        _ = try await model.performSessionOperation(
            .init(operation: .focus, session: original.id.uuidString))
        #expect(model.selected == original.id && worker.model.selected == original.id)
        await model.presentWorktrees(for: original)
        #expect(original.worktrees == [tree] && original.showsWorktrees)
        _ = try await model.performSessionOperation(.init(operation: .close, session: "2"))
        #expect(model.tabs.count == 1 && worker.model.tabs.count == 1)
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "quinjet.ui.open",
                payload: JSONSerialization.data(withJSONObject: [
                    "tabID": original.id.uuidString, "path": tree.path, "executable": "/bin/sh",
                    "configuration": [
                        "terminal": "embedded", "theme": ["rawValue": "quinjet"],
                        "appearance": "dark",
                    ],
                ]))
        }
        await model.shutdown()
        await worker.shutdown()
    }

    @Test func renderingStopCancelsNativeClientWithoutStoppingTheEngineOwnedPTY() async throws {
        defer { QuinjetWorkOwnership.enable() }
        let worker = QuinjetWorker(
            client: .init(execute: { _ in Data("[]".utf8) }), automaticActions: false)
        let engineHolder = try #require(worker.model.selectedTab?.holder)
        engineHolder.start(
            executable: "/bin/sh", arguments: ["-c", "printf '%s' $$; exec cat"],
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
            currentDirectory: "/private/tmp")
        let descriptor = try #require(engineHolder.descriptor)
        let transport = try OwnedTerminalClient(descriptor: descriptor) {
            try await worker.execute($0, payload: $1)
        }
        let first = try await transport.read(after: 0)
        let pid = try #require(Int32(String(decoding: first.bytes, as: UTF8.self)))
        let model = QuinjetPageModel(uiClient: .init { try await worker.execute($0, payload: $1) })
        await model.refreshUI()
        let renderingHolder = try #require(model.selectedTab?.holder)
        #expect(renderingHolder.descriptor == descriptor && renderingHolder.terminalLaunch == nil)
        let view = renderingHolder.retainedGhosttyView(theme: .init(palette: .edith(dark: true)))
        let window = TestWindowHost.window(contentRect: .init(x: 0, y: 0, width: 640, height: 400))
        view.frame = window.contentLayoutRect
        window.contentView = view
        defer { window.contentView = nil }
        await model.shutdown()
        #expect(renderingHolder.ghosttyView == nil && !view.receiveOutput(Data("stale".utf8)))
        #expect(kill(pid, 0) == 0)
        try await transport.input(Data("fixture-input\n".utf8))
        let output = try await transport.read(after: first.nextOffset)
        #expect(String(decoding: output.bytes, as: UTF8.self).contains("fixture-input"))
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        await worker.shutdown()
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func originalFolderBrowserLoadsSyntheticFilesOnlyThroughTheEngine() async throws {
        defer { QuinjetWorkOwnership.enable() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("synthetic.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = QuinjetWorker(
            client: .init(execute: { _ in Data("[]".utf8) }), automaticActions: false)
        let model = QuinjetPageModel(uiClient: .init { try await worker.execute($0, payload: $1) })
        await model.refreshUI()
        let picker = model.makeFolderPicker(for: try #require(model.selectedTab))
        await picker.navigate(to: root.path)
        #expect(picker.entries.map(\.name) == ["synthetic.txt"] && picker.errorMessage == nil)
        await picker.shutdown()
        await model.shutdown()
        await worker.shutdown()
    }

    @Test func checkedSnapshotRejectsLateGenerationsAndDisableReplies() async throws {
        defer { QuinjetWorkOwnership.enable() }
        let worker = QuinjetWorker(
            client: .init(execute: { _ in Data("[]".utf8) }), automaticActions: false)
        let first = try await worker.execute("quinjet.ui.read", payload: Data("{}".utf8))
        let second = try await worker.execute("quinjet.ui.read", payload: Data("{}".utf8))
        var changed = try #require(try JSONSerialization.jsonObject(with: second) as? [String: Any])
        changed["generation"] = UUID().uuidString
        let different = try JSONSerialization.data(withJSONObject: changed)
        var receipts = [second, first, different]
        let client = QuinjetUIClient { _, _ in receipts.removeFirst() }
        #expect(try await client.state("quinjet.ui.read") != nil)
        #expect(try await client.state("quinjet.ui.read") == nil)
        await #expect(throws: ExtensionPeerError.self) { try await client.state("quinjet.ui.read") }
        var continuation: CheckedContinuation<Data, Error>?
        let delayed = QuinjetUIClient { _, _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let pending = Task { try await delayed.state("quinjet.ui.read") }
        while continuation == nil { await Task.yield() }
        delayed.stop()
        continuation?.resume(returning: second)
        await #expect(throws: CancellationError.self) { try await pending.value }
        await worker.shutdown()
    }

    @Test func originalRemotePageRendersOffscreenAtCompactRegularZoomAndBothAppearances()
        async throws
    {
        defer { QuinjetWorkOwnership.enable() }
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        let worker = QuinjetWorker(
            client: .init(execute: { _ in
                try JSONEncoder().encode([
                    QuinjetProject(
                        name: "Synthetic review", commonDir: "/private/tmp/mock/.git",
                        worktrees: [
                            QuinjetWorktree(
                                path: "/private/tmp/mock", head: "1234567", branch: "fixture",
                                current: true, bare: false, detached: false, locked: nil,
                                prunable: nil)
                        ])
                ])
            }), automaticActions: false)
        for width in [620.0, 1100.0] {
            for dark in [false, true] {
                for zoom in [1.0, 1.4] {
                    UIScale.apply(zoom)
                    let model = QuinjetPageModel(
                        uiClient: .init { try await worker.execute($0, payload: $1) })
                    await model.refreshProjects()
                    let host = NSHostingView(
                        rootView: ExtensionPageHost {
                            QuinjetPage(model: model)
                                .environment(\.compactLayout, width < 720)
                                .environment(\.colorScheme, dark ? .dark : .light)
                                .environment(\.automaticViewActionsEnabled, false)
                                .environment(\.terminalLaunchEnabled, false)
                        })
                    let frame = NSRect(x: 0, y: 0, width: width, height: 760)
                    let window = TestWindowHost.window(contentRect: frame)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    host.frame = frame
                    host.layoutSubtreeIfNeeded()
                    await Task.yield()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                    #expect(host.fittingSize.width <= width + 1)
                    #expect(!TestWindowHost.isExposedOnDesktop(window))
                    window.close()
                    await model.shutdown()
                }
            }
        }
        await worker.shutdown()
    }
}
