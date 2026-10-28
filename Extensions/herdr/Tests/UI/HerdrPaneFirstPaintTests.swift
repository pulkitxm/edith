@testable import GhosttyTerminal
@testable import HerdrUI
import AppKit
import EdithExtensionSupport
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct HerdrPaneFirstPaintTests {
    private func launch(_ command: String) -> OwnedTerminalLaunch {
        .init(
            executable: "/bin/sh", arguments: ["-c", command],
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
            currentDirectory: "/private/tmp", allowsLocalFileLinks: true,
            resetTerminalAfterInterrupt: false)
    }

    private func text(_ holder: TerminalSessionHolder) -> String? {
        guard let view = holder.ghosttyView, view.performBindingAction("select_all") else {
            return nil
        }
        return view.selectedText()
    }

    private func paint(_ holder: TerminalSessionHolder, marker: String, page: RenderedHerdrPage)
        async -> Bool
    {
        for _ in 0..<100 {
            await page.settle()
            if text(holder)?.contains(marker) == true { return true }
        }
        return false
    }

    @Test func aReplacedSessionHolderIsConnectedAndPaintsWithoutAnyInteraction() async throws {
        let page = try await RenderedHerdrPage(terminalLaunch: true)
        defer { page.close() }
        let session = try await OwnedTerminalSession(launch: launch("printf replaced-paint; sleep 30"))
        defer { session.stop() }
        let descriptor = session.descriptor
        page.store.terminalClient = { operation, payload in
            if operation == "herdr.terminal.open" { return try JSONEncoder().encode(descriptor) }
            return try await session.execute(operation, payload: payload)
        }
        page.store.open(page.agents[0])
        let first = try #require(page.store.session(page.agents[0].id)).holder
        #expect(await paint(first, marker: "replaced-paint", page: page))
        page.store.close(page.agents[0].id)
        page.store.open(page.agents[0])
        let second = try #require(page.store.session(page.agents[0].id)).holder
        #expect(second !== first)
        #expect(await paint(second, marker: "replaced-paint", page: page))
        second.stop()
    }

    @Test func anActiveTabPaintsItsTerminalWithoutAnyInteraction() async throws {
        let page = try await RenderedHerdrPage()
        defer { page.close() }
        page.store.open(page.agents[0])
        let holder = try #require(page.store.session(page.agents[0].id)).holder
        let session = try await OwnedTerminalSession(launch: launch("printf first-paint; sleep 30"))
        defer { session.stop() }
        holder.bind(
            try OwnedTerminalClient(descriptor: session.descriptor) { operation, payload in
                try await session.execute(operation, payload: payload)
            })
        var painted = false
        for _ in 0..<100 {
            await page.settle()
            if text(holder)?.contains("first-paint") == true { painted = true; break }
        }
        #expect(painted)
        #expect(holder.ghosttyView?.renderingActive == true)
        holder.stop()
    }
}
