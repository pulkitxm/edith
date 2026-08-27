import AppKit
@testable import Edith
@testable import EdithKit
@testable import GhosttyTerminal
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

    @Test func terminalPaletteChangesWithTheAppTheme() {
        let blue = TerminalPalette.edith(dark: true, theme: .blue)
        let orange = TerminalPalette.edith(dark: true, theme: .orange)

        #expect(blue != orange)
        #expect(blue.ansi.count == 16)
        #expect(orange.ansi.count == 16)
        #expect(!blue.selectionBackground.isEqual(blue.background))
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
        #expect(view.terminal.getBufferAsData().count < 512 * 1024)

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

        #expect(holder.presentationGeneration == 20_000)
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

    @Test func ghosttySurfaceIdentitySurvivesRepresentableReconstruction() {
        let key = AppStorageKeys.Herdr.ghosttyTerminal
        let previous = SharedDefaults.store.object(forKey: key)
        SharedDefaults.store.set(true, forKey: key)
        defer {
            if let previous {
                SharedDefaults.store.set(previous, forKey: key)
            } else {
                SharedDefaults.store.removeObject(forKey: key)
            }
        }

        let holder = TerminalSessionHolder()
        holder.start(executable: "/usr/bin/true", arguments: [], environment: [])
        let launch = holder.ghosttyLaunch!
        let theme = GhosttyTheme(palette: .edith(dark: true))
        let first = holder.retainedGhosttyView(launch: launch, theme: theme)
        let second = holder.retainedGhosttyView(launch: launch, theme: theme)

        #expect(first === second)
    }
}
