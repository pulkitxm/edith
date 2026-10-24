import AppKit
import Foundation
import ImageIO
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite(.serialized) struct HerdrStartupEvidenceTests {
    nonisolated private static let evidenceKey = "EDITH_HERDR_STARTUP_EVIDENCE_DIR"

    @Test(.enabled(if: ProcessInfo.processInfo.environment[evidenceKey] != nil))
    func lateConfirmationRemovesTheWarningFromTheRunningTerminal() async throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try #require(environment["EDITH_TEST_RUNTIME_ROOT"])
        let dataRoot = try #require(environment["EDITH_DATA_ROOT"])
        try #require(dataRoot.hasPrefix(runtime + "/"))
        let output = URL(
            fileURLWithPath: try #require(environment[Self.evidenceKey]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let suite = "HerdrStartupEvidenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let previous = GhosttyTerminals.defaults
        defaults.set(false, forKey: AppStorageKeys.Herdr.ghosttyTerminal)
        GhosttyTerminals.defaults = defaults
        defer {
            GhosttyTerminals.defaults = previous
            defaults.removePersistentDomain(forName: suite)
        }

        for dark in [true, false] {
            let store = HerdrStore(
                liveWatcher: { _ in },
                newAgentPaneCreator: { _, _, _, _, _ in
                    HerdrCreatedPane(workspaceID: "w1", tabID: "w1:t2", paneID: "w1:p2")
                },
                agentStarter: { _, _, _ in
                    throw HerdrCommandError.commandFailed(
                        #"{"error":{"code":"timeout","message":"Startup timed out"}}"#)
                }, machinesProvider: { [] })
            defer { store.closeAll() }
            try await store.launchNewAgent(
                kind: "Codex", host: .local(herdrPresent: true), existingSpace: nil,
                newSpaceLabel: "Startup demo")
            var tab = try #require(store.focusedSession)
            tab.view = .agent
            await store.agentStartupTasks[tab.id]?.value
            try #require(store.agentStartupMessages[tab.id] != nil)
            tab.holder.start(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "printf '\\033[2J\\033[H\n\n\n\n  demo terminal\n\n  Ready for input\n\n> '; exec /bin/cat",
                ], environment: ["TERM=xterm-256color", "LANG=en_US.UTF-8"],
                currentDirectory: "/tmp")
            let host = NSHostingView(
                rootView: HerdrSessionView(
                    store: store, tab: tab, launchEnabled: false, showsDetails: false
                )
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.machineConnectionsEnabled, false)
                .environment(\.terminalLaunchEnabled, false)
                .environment(\.colorScheme, dark ? .dark : .light)
                .transaction { $0.animation = nil })
            host.frame = NSRect(x: 0, y: 0, width: dark ? 1200 : 640, height: 360)
            let window = TestWindowHost.window(contentRect: host.frame)
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }
            window.backgroundColor = TerminalPalette.edith(dark: dark).background
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderBack(nil)
            let name = dark ? "regular-dark" : "compact-light"
            try await capture(
                window, host: host, to: output.appendingPathComponent(name + "-before.png"))

            var ready = tab.agent
            ready.status = .idle
            store.apply([.local(herdrPresent: true, agents: [ready])])
            #expect(store.agentStartupMessages[tab.id] == nil)
            #expect(tab.holder.started)
            try await capture(
                window, host: host, to: output.appendingPathComponent(name + "-after.png"))
        }
    }

    private func capture(_ window: NSWindow, host: NSView, to output: URL) async throws {
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            redraw(host)
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(window.backgroundColor.cgColor)
        context.fill(bounds)
        context.draw(image, in: bounds)
        let captured = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, captured, nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func redraw(_ view: NSView) {
        for child in view.subviews { redraw(child) }
        view.needsDisplay = true
        view.displayIfNeeded()
    }
}
