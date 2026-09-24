import AppKit
@testable import Edith
@testable import EdithKit
@testable import GhosttyTerminal
import Testing

@Suite(.serialized) @MainActor struct TerminalPresentationTests {
    @Test func terminalPaletteChangesWithTheAppTheme() {
        let blue = TerminalPalette.edith(dark: true, theme: .blue)
        let orange = TerminalPalette.edith(dark: true, theme: .orange)

        #expect(blue != orange)
        #expect(blue.ansi.count == 16)
        #expect(orange.ansi.count == 16)
        #expect(!blue.selectionBackground.isEqual(blue.background))
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

    @Test func terminalResponderBypassesTypeAheadAndMediaShortcuts() throws {
        let holder = TerminalSessionHolder()
        holder.start(executable: "/usr/bin/true", arguments: [], environment: [])
        defer { holder.stop() }
        let responder = holder.retainedGhosttyView(
            launch: try #require(holder.ghosttyLaunch),
            theme: GhosttyTheme(palette: .edith(dark: true)))
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

    @Test func exitedGhosttySessionTearsDownAndCanRestart() async throws {
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

    @Test func confirmingGhosttyCloseCompletesTheUserRequest() async throws {
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

    @Test func resetDiscardsStaleMetadataAndQueuedGhosttyInput() async throws {
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

    @Test func queuedGhosttyInputFlushesOnceWhenTheViewIsRetained() async throws {
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

    @Test func ghosttySurfaceIdentitySurvivesRepresentableReconstruction() {
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

}
