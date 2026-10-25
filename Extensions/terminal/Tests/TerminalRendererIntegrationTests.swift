import AppKit
@testable import GhosttyTerminal
import Testing
@testable import TerminalExtension

@Suite(.serialized) @MainActor struct TerminalRendererIntegrationTests {
    @Test func realOwnedPTYFeedsOriginalRendererAndReceivesNativeInputAndResize() async throws {
        let engine = TerminalTestFixture.engine(
            "stty icanon icrnl opost onlcr -echo; printf 'ready\\n'; IFS= read -r value; printf '\\033[31mowned:%s\\033[0m\\n' \"$value\"; stty size; printf '\\033]0;Fixture title\\007'; exit 7"
        )
        defer { engine.stop() }
        let remote = try TerminalTestFixture.remote(engine)
        let model = TerminalTabsModel(client: remote)
        defer { model.stopAll() }
        await remote.open()
        model.synchronize()
        let tab = try #require(model.tabs.first)
        let window = TerminalTestFixture.window(NSSize(width: 640, height: 400))
        let view = tab.holder.retainedGhosttyView(
            theme: GhosttyTheme(background: "#000000", foreground: "#ffffff", cursor: "#ffffff"))
        view.frame = window.contentLayoutRect
        window.contentView = view
        defer { window.contentView = nil; view.shutdown() }
        try await TerminalTestFixture.wait {
            (view.accessibilityValue() as? String)?.contains("ready") == true
        }
        let mode = try await remote.read(tab.holder.session, after: 0)
        #expect(mode.canonical && !mode.echo)
        view.setFrameSize(NSSize(width: 900, height: 500))
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.insertText("synthetic-input\r"))
        try await TerminalTestFixture.wait {
            tab.holder.exitMessage == "Session ended with status 7."
        }
        let screen = try #require(view.accessibilityValue() as? String)
        #expect(screen.contains("owned:synthetic-input"))
        #expect(!screen.contains("\u{1b}[31m"))
        #expect(tab.holder.currentTitle == "Fixture title")
        #expect(tab.holder.error == nil)
        #expect(view.performBindingAction("select_all"))
        #expect(view.selectedText()?.contains("owned:synthetic-input") == true)
        #expect(!view.receiveOutput(Data("late".utf8)))
        #expect(!window.isVisible)
    }

    @Test func restartRejectsOldGenerationAndDisableReleasesRendererAndOwnedPTY() async throws {
        let engine = TerminalTestFixture.engine()
        let remote = try TerminalTestFixture.remote(engine)
        let model = TerminalTabsModel(client: remote)
        defer { model.stopAll(); engine.stop() }
        await remote.open(); model.synchronize()
        let first = try #require(model.tabs.first)
        let window = TerminalTestFixture.window(NSSize(width: 640, height: 400))
        let view = first.holder.retainedGhosttyView(
            theme: GhosttyTheme(background: "#000000", foreground: "#ffffff", cursor: "#ffffff"))
        view.frame = window.contentLayoutRect
        window.contentView = view
        defer { window.contentView = nil }
        #expect(view.insertText("before-restart"))
        try await TerminalTestFixture.wait {
            (view.accessibilityValue() as? String)?.contains("before-restart") == true
        }
        let generation = first.holder.generation
        model.restart(first.id)
        try await TerminalTestFixture.wait { model.tabs.first?.holder.generation != generation }
        #expect(first.holder.ghosttyView == nil && !view.receiveOutput(Data("stale".utf8)))
        model.stopAll()
        #expect(remote.isStopped && model.tabs.isEmpty)
        #expect(try engine.snapshot().sessions.count == 1)
        engine.stop()
        #expect(engine.isStopped)
    }
}
