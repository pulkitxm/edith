@testable import GhosttyTerminal
@testable import HerdrUI
import AppKit
import EdithExtensionSupport
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct HerdrTerminalFocusFlowTests {
    private func launch(_ command: String) -> OwnedTerminalLaunch {
        .init(
            executable: "/bin/sh", arguments: ["-c", command],
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
            currentDirectory: "/private/tmp", allowsLocalFileLinks: true,
            resetTerminalAfterInterrupt: false)
    }

    private struct Setup {
        let page: RenderedHerdrPage
        let first: TerminalSessionHolder
        let second: TerminalSessionHolder
        let sessions: [OwnedTerminalSession]
        let presentation: OwnedTerminalUIPresentation
        let id: UUID
    }

    private func setup() async throws -> Setup {
        let page = try await RenderedHerdrPage()
        page.store.open(page.agents[0])
        page.store.open(page.agents[1], beside: .right)
        let first = try #require(page.store.session(page.agents[0].id)).holder
        let second = try #require(page.store.session(page.agents[1].id)).holder
        var sessions: [OwnedTerminalSession] = []
        for (holder, marker) in [(first, "pane-one"), (second, "pane-two")] {
            let session = try await OwnedTerminalSession(
                launch: launch("stty raw -echo; printf " + marker + "; cat"))
            sessions.append(session)
            holder.bind(
                try OwnedTerminalClient(descriptor: session.descriptor) { operation, payload in
                    try await session.execute(operation, payload: payload)
                })
        }
        for _ in 0..<60 { await page.settle() }
        let id = UUID()
        let presentation = page.store.makeTerminalUIPresentation(
            id: id, location: "main", target: "", token: nil)
        page.store.terminalUI = presentation
        return Setup(
            page: page, first: first, second: second, sessions: sessions,
            presentation: presentation, id: id)
    }

    private func send(_ setup: Setup, sequence: UInt64, active: Bool, key: Bool, visible: Bool) {
        let event = OwnedTerminalUIEvent(
            version: 1, presentationID: setup.id, sequence: sequence, active: active, key: key,
            visible: visible, action: nil)
        let payload = try! JSONEncoder().encode(event)
        let result = setup.presentation.execute([
            "presentationID": setup.id.uuidString, "operation": "terminalUI", "payload": payload,
        ])
        #expect(result["ok"] as? Bool == true)
    }

    private func settle(_ setup: Setup) async {
        for _ in 0..<20 { await setup.page.settle() }
    }

    private func report(_ setup: Setup, _ session: OwnedTerminalSession) async throws -> String {
        let client = try OwnedTerminalClient(descriptor: session.descriptor) { operation, payload in
            try await session.execute(operation, payload: payload)
        }
        var output = Data()
        for _ in 0..<10 {
            let chunk = try await client.read(after: UInt64(output.count))
            output.append(chunk.bytes)
            if chunk.bytes.isEmpty { break }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func click(_ view: NSView, in window: NSWindow) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: 1)!
            window.sendEvent(event)
        }
    }

    @Test func clickingASplitPaneFocusesItsSurfaceAndReportsFocusIn() async throws {
        let s = try await setup()
        defer { s.page.close(); s.sessions.forEach { $0.stop() } }
        let b = try #require(s.second.ghosttyView)
        let a = try #require(s.first.ghosttyView)
        #expect(b.receiveOutput(Data("\u{1b}[?1004h".utf8)))
        #expect(a.receiveOutput(Data("\u{1b}[?1004h".utf8)))
        send(s, sequence: 1, active: true, key: true, visible: true)
        let window = try #require(b.window)
        click(b, in: window)
        await settle(s)
        #expect(window.firstResponder === b)
        #expect(b.surfaceFocused)
        #expect(!a.surfaceFocused)
        let text = try await report(s, s.sessions[1])
        #expect(text.contains("\u{1b}[I"))
    }

    @Test func storeFocusFocusesItsSurface() async throws {
        let s = try await setup()
        defer { s.page.close(); s.sessions.forEach { $0.stop() } }
        send(s, sequence: 1, active: true, key: true, visible: true)
        s.page.store.focus(s.page.agents[1].id)
        await settle(s)
        let b = try #require(s.second.ghosttyView)
        #expect(b.window?.firstResponder === b)
        #expect(b.surfaceFocused)
        #expect(s.first.ghosttyView?.surfaceFocused == false)
    }

    @Test func aViewCreatedAfterTheLastEventStillGetsTheHostState() async throws {
        let s = try await setup()
        defer { s.page.close(); s.sessions.forEach { $0.stop() } }
        send(s, sequence: 1, active: true, key: true, visible: true)
        s.second.stopRendering()
        s.page.store.focus(s.page.agents[1].id)
        let session = try await OwnedTerminalSession(launch: launch("stty raw -echo; cat"))
        defer { session.stop() }
        s.second.bind(
            try OwnedTerminalClient(descriptor: session.descriptor) { operation, payload in
                try await session.execute(operation, payload: payload)
            })
        await settle(s)
        let b = try #require(s.second.ghosttyView)
        #expect(b.window?.firstResponder === b)
        #expect(b.surfaceFocused)
    }

    @Test func focusReportingEnabledAfterTheSurfaceWasFocusedStillReportsFocusIn() async throws {
        let s = try await setup()
        defer { s.page.close(); s.sessions.forEach { $0.stop() } }
        send(s, sequence: 1, active: true, key: true, visible: true)
        s.page.store.focus(s.page.agents[1].id)
        await settle(s)
        let b = try #require(s.second.ghosttyView)
        #expect(b.surfaceFocused)
        #expect(b.receiveOutput(Data("\u{1b}[?1004h".utf8)))
        await settle(s)
        let text = try await report(s, s.sessions[1])
        #expect(text.contains("\u{1b}[I"))
    }

    @Test func aPaneOpenedAfterTheLastHostEventStillGetsTheHostWindowState() async throws {
        let s = try await setup()
        defer { s.page.close(); s.sessions.forEach { $0.stop() } }
        send(s, sequence: 1, active: true, key: true, visible: true)
        s.page.store.open(s.page.agents[2], beside: .bottom)
        let third = try #require(s.page.store.session(s.page.agents[2].id)).holder
        let session = try await OwnedTerminalSession(launch: launch("stty raw -echo; cat"))
        defer { session.stop() }
        third.bind(
            try OwnedTerminalClient(descriptor: session.descriptor) { operation, payload in
                try await session.execute(operation, payload: payload)
            })
        s.page.store.focus(s.page.agents[2].id)
        await settle(s)
        let view = try #require(third.ghosttyView)
        #expect(view.window?.firstResponder === view)
        #expect(view.surfaceFocused)
    }

    @Test func aResetHolderKeepsTheHostWindowState() async throws {
        let s = try await setup()
        defer { s.page.close(); s.sessions.forEach { $0.stop() } }
        send(s, sequence: 1, active: true, key: true, visible: true)
        s.second.reset()
        let session = try await OwnedTerminalSession(launch: launch("stty raw -echo; cat"))
        defer { session.stop() }
        s.second.bind(
            try OwnedTerminalClient(descriptor: session.descriptor) { operation, payload in
                try await session.execute(operation, payload: payload)
            })
        s.page.store.focus(s.page.agents[1].id)
        await settle(s)
        let view = try #require(s.second.ghosttyView)
        #expect(view.window?.firstResponder === view)
        #expect(view.surfaceFocused)
    }
}
