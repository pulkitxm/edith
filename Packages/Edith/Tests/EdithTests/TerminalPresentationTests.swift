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

    @Test func disconnectedTerminalOffersAWorkingConnectAction() {
        let presentation = MachineTerminalPresentation.make(
            state: .disconnected, target: "tuf-wired", isLocal: false, started: false,
            exitMessage: nil, launchEnabled: true)

        #expect(presentation.title == "Not connected")
        #expect(presentation.detail == "Connect to tuf-wired to start a terminal.")
        #expect(presentation.action == .connect)
        #expect(presentation.showsTerminal == false)
    }

    @Test func reconnectingTerminalShowsTheLatestFailureWithoutAFakeRetry() {
        let presentation = MachineTerminalPresentation.make(
            state: .reconnecting(message: "Connection timed out."), target: "tuf-wired",
            isLocal: false, started: false, exitMessage: nil, launchEnabled: true)

        #expect(presentation.title == "Reconnecting to tuf-wired…")
        #expect(presentation.detail == "Connection timed out.")
        #expect(presentation.showsProgress)
        #expect(presentation.action == nil)
    }

    @Test func failedTerminalShowsTheReasonAndARealRetry() {
        let presentation = MachineTerminalPresentation.make(
            state: .failed(message: "Connection refused.", recoverable: true),
            target: "tuf-wired", isLocal: false, started: false,
            exitMessage: "Session ended with status 255.",
            launchEnabled: true)

        #expect(presentation.title == "Couldn’t connect to tuf-wired")
        #expect(presentation.detail == "Connection refused.")
        #expect(presentation.action == .retry)
        #expect(presentation.showsTerminal == false)
    }

    @Test func runningAndEndedTerminalsExposeOnlyValidActions() {
        let running = MachineTerminalPresentation.make(
            state: .connected(latencyMillis: 4), target: "tuf-wired", isLocal: false,
            started: true, exitMessage: nil, launchEnabled: true)
        let ended = MachineTerminalPresentation.make(
            state: .connected(latencyMillis: 4), target: "tuf-wired", isLocal: false,
            started: false, exitMessage: "Session ended.", launchEnabled: true)

        #expect(running.showsTerminal)
        #expect(running.action == .restart)
        #expect(ended.showsTerminal == false)
        #expect(ended.action == .start)
    }

    @Test func exitedHerdrAgentOffersRestartInsteadOfABlankPane() {
        let ended = HerdrAgentTerminalOverlay.make(
            connectError: nil, starting: false, started: false,
            exitMessage: "Session ended with status 1.")
        let running = HerdrAgentTerminalOverlay.make(
            connectError: nil, starting: false, started: true,
            exitMessage: "Session ended with status 1.")

        #expect(ended == .ended("Session ended with status 1."))
        #expect(ended.offersRestart)
        #expect(running == .none)
        #expect(!running.offersRestart)
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

    @Test func ghosttyMetadataCallbacksReachTheSharedHolder() async throws {
        try await withGhosttyEnabled(true) {
            let holder = TerminalSessionHolder()
            holder.start(
                executable: "/usr/bin/true", arguments: [], environment: [],
                currentDirectory: "/tmp/starting")
            let launch = try #require(holder.ghosttyLaunch)
            let view = holder.retainedGhosttyView(
                launch: launch, theme: GhosttyTheme(palette: .edith(dark: true)))

            view.setTerminalTitle("build logs")
            view.setWorkingDirectory("/tmp/current")
            await Task.yield()

            #expect(holder.currentTitle == "build logs")
            #expect(holder.currentWorkingDirectory == "/tmp/current")
            holder.reset()
        }
    }

    @Test func exitedGhosttySessionTearsDownAndCanRestart() async throws {
        try await withGhosttyEnabled(true) {
            let holder = TerminalSessionHolder()
            holder.start(executable: "/usr/bin/true", arguments: [], environment: [])
            let launch = try #require(holder.ghosttyLaunch)
            let theme = GhosttyTheme(palette: .edith(dark: true))
            let first = holder.retainedGhosttyView(launch: launch, theme: theme)
            first.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            let window = TestWindowHost.window(contentRect: first.frame)
            window.contentView = first
            defer {
                holder.stop()
                window.contentView = nil
            }

            for _ in 0..<300 {
                if !holder.started { break }
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(!holder.started)
            #expect(holder.exitMessage == "Session ended.")
            #expect(holder.ghosttyLaunch == nil)
            #expect(holder.ghosttyView == nil)
            #expect(first.surface == nil)
            let finishedGeneration = holder.generation

            holder.start(executable: "/bin/cat", arguments: [], environment: [])
            let restartedLaunch = try #require(holder.ghosttyLaunch)
            let second = holder.retainedGhosttyView(launch: restartedLaunch, theme: theme)
            window.contentView = second

            #expect(holder.started)
            #expect(holder.generation == finishedGeneration)
            #expect(second !== first)
        }
    }

    @Test func cancellingGhosttyCloseLeavesTheSessionAndClearsTheRequest() async throws {
        try await withGhosttyEnabled(true) {
            var closeRequests = 0
            let holder = TerminalSessionHolder(requestGhosttyClose: { _ in
                closeRequests += 1
                return true
            })
            holder.start(executable: "/bin/cat", arguments: [], environment: [])
            let launch = try #require(holder.ghosttyLaunch)
            let view = holder.retainedGhosttyView(
                launch: launch, theme: GhosttyTheme(palette: .edith(dark: true)))
            var decisions: [Bool] = []

            holder.requestUserClose { decisions.append($0) }
            view.onCloseRequestCancelled?()
            await Task.yield()

            #expect(closeRequests == 1)
            #expect(decisions == [false])
            #expect(holder.started)
            #expect(holder.ghosttyView === view)
            #expect(holder.ghosttyLaunch != nil)

            view.onClose?(0)
            await Task.yield()

            #expect(decisions == [false])
            #expect(holder.ghosttyView == nil)
            #expect(holder.ghosttyLaunch == nil)
        }
    }

    @Test func confirmingGhosttyCloseCompletesTheUserRequest() async throws {
        try await withGhosttyEnabled(true) {
            let holder = TerminalSessionHolder(requestGhosttyClose: { _ in true })
            holder.start(executable: "/bin/cat", arguments: [], environment: [])
            let launch = try #require(holder.ghosttyLaunch)
            let view = holder.retainedGhosttyView(
                launch: launch, theme: GhosttyTheme(palette: .edith(dark: true)))
            var decisions: [Bool] = []

            holder.requestUserClose { decisions.append($0) }
            view.onClose?(0)
            await Task.yield()

            #expect(decisions == [true])
            #expect(holder.ghosttyView == nil)
            #expect(holder.ghosttyLaunch == nil)
        }
    }

    @Test func swiftTermMetadataCallbacksReachTheSharedHolder() async {
        await withGhosttyEnabled(false) {
            let holder = TerminalSessionHolder()
            holder.start(
                executable: "/bin/cat", arguments: [], environment: [],
                currentDirectory: "/tmp/starting")
            let view = holder.terminalView

            view.setTerminalTitle(source: view, title: "remote shell")
            view.hostCurrentDirectoryUpdate(source: view, directory: "/tmp/remote")
            await Task.yield()

            #expect(holder.currentTitle == "remote shell")
            #expect(holder.currentWorkingDirectory == "/tmp/remote")
            holder.reset()
        }
    }

    @Test func resetDiscardsStaleMetadataAndQueuedGhosttyInput() async throws {
        try await withGhosttyEnabled(true) {
            var deliveries: [String] = []
            let holder = TerminalSessionHolder(deliverGhosttyInput: { _, text in
                deliveries.append(text)
                return false
            })
            holder.start(
                executable: "/usr/bin/true", arguments: [], environment: [],
                currentDirectory: "/tmp/starting")
            holder.sendInput("stale input")
            let launch = try #require(holder.ghosttyLaunch)
            let view = holder.retainedGhosttyView(
                launch: launch, theme: GhosttyTheme(palette: .edith(dark: true)))
            view.setTerminalTitle("stale title")
            view.setWorkingDirectory("/tmp/stale")

            holder.reset()
            await Task.yield()
            view.setTerminalTitle("later stale title")
            view.setWorkingDirectory("/tmp/later-stale")
            view.onReady?()
            await Task.yield()

            #expect(holder.currentTitle == nil)
            #expect(holder.currentWorkingDirectory == nil)
            #expect(deliveries == ["stale input"])
        }
    }

    @Test func stopInvalidatesTheSessionAndCreatesAFreshFallbackView() async {
        await withGhosttyEnabled(false) {
            let holder = TerminalSessionHolder()
            let original = holder.terminalView
            holder.start(executable: "/bin/cat", arguments: [], environment: [])
            let runningGeneration = holder.generation

            holder.stop()

            #expect(!holder.started)
            #expect(holder.generation == runningGeneration + 1)
            #expect(holder.terminalView !== original)
            #expect(holder.currentTitle == nil)
            #expect(holder.currentWorkingDirectory == nil)
        }
    }

    @Test func queuedGhosttyInputFlushesOnceWhenTheViewIsRetained() async throws {
        try await withGhosttyEnabled(true) {
            var deliveries: [String] = []
            let holder = TerminalSessionHolder(deliverGhosttyInput: { _, text in
                deliveries.append(text)
                return true
            })
            holder.start(executable: "/usr/bin/true", arguments: [], environment: [])
            holder.sendInput("first ")
            holder.insertText("second")
            #expect(deliveries.isEmpty)

            let launch = try #require(holder.ghosttyLaunch)
            let theme = GhosttyTheme(palette: .edith(dark: true))
            let first = holder.retainedGhosttyView(launch: launch, theme: theme)
            let second = holder.retainedGhosttyView(launch: launch, theme: theme)
            for _ in 0..<10 {
                if !deliveries.isEmpty { break }
                await Task.yield()
            }

            #expect(first === second)
            #expect(deliveries == ["first second"])
            _ = holder.retainedGhosttyView(launch: launch, theme: theme)
            await Task.yield()
            #expect(deliveries == ["first second"])
            holder.reset()
        }
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

    @Test func ghosttyFocusRequestsOnlyFireOnOwnershipTransitions() {
        let coordinator = GhosttyPane.Coordinator()

        #expect(coordinator.shouldRequest(active: true, wantsFocus: true))
        #expect(!coordinator.shouldRequest(active: true, wantsFocus: true))
        #expect(!coordinator.shouldRequest(active: false, wantsFocus: true))
        #expect(coordinator.shouldRequest(active: true, wantsFocus: true))
        #expect(!coordinator.shouldRequest(active: true, wantsFocus: false))
    }

    @Test func ghosttyViewReportsResponderOwnership() async throws {
        try await withGhosttyEnabled(true) {
            let holder = TerminalSessionHolder()
            holder.start(executable: "/bin/cat", arguments: [], environment: [])
            let launch = try #require(holder.ghosttyLaunch)
            let view = holder.retainedGhosttyView(
                launch: launch, theme: GhosttyTheme(palette: .edith(dark: true)))
            let window = TestWindowHost.window(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
            window.contentView = view
            _ = window.makeFirstResponder(nil)
            var focusReports = 0
            view.onFocus = { focusReports += 1 }
            defer {
                holder.stop()
                window.contentView = nil
            }

            #expect(window.makeFirstResponder(view))
            #expect(focusReports == 1)
        }
    }

    @Test func ghosttyIsTheDefaultTerminalWithAnExplicitFallback() {
        let key = AppStorageKeys.Herdr.ghosttyTerminal
        let previous = SharedDefaults.store.object(forKey: key)
        defer {
            if let previous {
                SharedDefaults.store.set(previous, forKey: key)
            } else {
                SharedDefaults.store.removeObject(forKey: key)
            }
        }

        SharedDefaults.store.removeObject(forKey: key)
        #expect(GhosttyTerminals.enabled)
        SharedDefaults.store.set(false, forKey: key)
        #expect(!GhosttyTerminals.enabled)
    }

    @Test func ghosttyRendersOnlyWhileItsSurfaceIsVisible() {
        #expect(GhosttyTerminalView.shouldRender(active: true, hidden: false, windowVisible: true))
        #expect(
            !GhosttyTerminalView.shouldRender(active: false, hidden: false, windowVisible: true))
        #expect(!GhosttyTerminalView.shouldRender(active: true, hidden: true, windowVisible: true))
        #expect(
            !GhosttyTerminalView.shouldRender(active: true, hidden: false, windowVisible: false))
        #expect(
            GhosttyTerminalView.shouldFocus(
                active: true, keyWindow: true, firstResponder: true))
        #expect(
            !GhosttyTerminalView.shouldFocus(
                active: true, keyWindow: false, firstResponder: true))
        #expect(
            !GhosttyTerminalView.shouldFocus(
                active: true, keyWindow: true, firstResponder: false))
        #expect(
            GhosttyTerminalView.shouldConsumeFocusClick(
                appActive: true, keyWindow: true, focused: false, hitSurface: true))
        #expect(
            !GhosttyTerminalView.shouldConsumeFocusClick(
                appActive: false, keyWindow: true, focused: false, hitSurface: true))
        #expect(
            !GhosttyTerminalView.shouldConsumeFocusClick(
                appActive: true, keyWindow: true, focused: true, hitSurface: true))
        #expect(
            !GhosttyTerminalView.shouldConsumeFocusClick(
                appActive: true, keyWindow: true, focused: false, hitSurface: true,
                activatesTerminalLink: true))
    }

    private func withGhosttyEnabled(
        _ enabled: Bool, operation: () async throws -> Void
    ) async rethrows {
        let key = AppStorageKeys.Herdr.ghosttyTerminal
        let previous = SharedDefaults.store.object(forKey: key)
        SharedDefaults.store.set(enabled, forKey: key)
        defer {
            if let previous {
                SharedDefaults.store.set(previous, forKey: key)
            } else {
                SharedDefaults.store.removeObject(forKey: key)
            }
        }
        try await operation()
    }
}
