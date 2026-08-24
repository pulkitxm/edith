import AppKit
@testable import Edith
@testable import EdithKit
import Testing

@Suite(.serialized) @MainActor struct TerminalPresentationTests {
    @Test func repeatedEquivalentThemesApplyOnceWithinTheResponsivenessBudget() {
        let holder = TerminalSessionHolder()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<25_000 {
                holder.applyTheme(.edith(dark: true))
            }
        }

        #expect(holder.themeApplicationCount == 1)
        #expect(elapsed < .seconds(1))

        holder.applyTheme(.edith(dark: false))
        #expect(holder.themeApplicationCount == 2)
    }

    @Test func inactiveTerminalCoalescesFloodRedrawAndKeepsBoundedHistory() async throws {
        let holder = TerminalSessionHolder()
        let view = holder.terminalView
        holder.updatePresentation(active: false, wantsFocus: false)
        view.needsDisplay = false

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for index in 0..<20_000 {
                view.feed(text: "line-\(index)\n")
            }
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(elapsed < .seconds(3))
        #expect(view.isHidden)
        #expect(view.hasDeferredDisplay)
        #expect(view.deferredDisplayPasses == 1)
        #expect(view.terminal.getBufferAsData().count < 128 * 1024)

        holder.updatePresentation(active: true, wantsFocus: false)

        #expect(!view.isHidden)
        #expect(!view.hasDeferredDisplay)
        #expect(view.reactivationDisplayPasses == 1)
    }

    @Test func presentationChangesDoNotAccumulateStaleFocusWork() async {
        let holder = TerminalSessionHolder()

        for _ in 0..<10_000 {
            holder.updatePresentation(active: true, wantsFocus: true)
            holder.updatePresentation(active: false, wantsFocus: false)
        }
        await Task.yield()

        #expect(holder.terminalView.isHidden)
        #expect(!holder.terminalView.renderingActive)
    }

    @Test func inactiveAndDisconnectedTerminalsDoNotLaunch() {
        #expect(
            !TerminalLaunchPolicy.shouldStart(
                active: false, launchEnabled: true, started: false, isLocal: true,
                connected: true))
        #expect(
            !TerminalLaunchPolicy.shouldStart(
                active: true, launchEnabled: true, started: false, isLocal: false,
                connected: false))
        #expect(
            TerminalLaunchPolicy.shouldStart(
                active: true, launchEnabled: true, started: false, isLocal: true,
                connected: false))
    }

    @Test func terminalResponderBypassesTypeAheadAndMediaShortcuts() {
        let responder = TerminalSessionHolder().terminalView
        let clock = ContinuousClock()
        var typeAheadStarts = 0
        var textInputMatches = 0
        let elapsed = clock.measure {
            for _ in 0..<100_000 {
                if InputFocus.shouldStartTypeAhead(
                    characters: "x", modifiers: [], responder: responder)
                {
                    typeAheadStarts += 1
                }
                if MusicKeyCommand.isReceivingTextInput(responder) {
                    textInputMatches += 1
                }
            }
        }

        #expect(typeAheadStarts == 0)
        #expect(textInputMatches == 100_000)
        #expect(elapsed < .seconds(1))
    }
}
