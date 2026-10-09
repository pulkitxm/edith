import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Testing
@testable import QuinjetUI

@MainActor
@Suite struct QuinjetPageModelTests {
    @Test func nativeSessionStatusDescribesTheSelectedPicker() async throws {
        let model = QuinjetPageModel(client: client)

        let result = try await model.performSessionOperation(
            QuinjetSessionRequest(operation: .status))

        let session = try #require(result.sessions.first)
        #expect(result.selectedSessionID == session.id)
        #expect(session.index == 1)
        #expect(session.title == "New review")
        #expect(session.selected)
        #expect(session.state == "picker")
        #expect(session.terminal == nil)
        #expect(!session.canClose)
        #expect(!session.canRestart)
    }

    @Test func nativeFocusSelectsTheTabAndFocusesItsCMUXWorkspace() async throws {
        let recorder = QuinjetWorkspaceRecorder()
        let model = QuinjetPageModel(
            client: client,
            focusExternalWorkspace: { recorder.focus($0) },
            closeExternalWorkspace: { recorder.close($0) })
        let tab = try #require(model.selectedTab)
        let configuration = QuinjetLaunchConfiguration(
            terminal: .cmux, theme: .quinjet, appearance: .dark)
        model.open(
            Self.main, projectName: "edith", available: [Self.main], in: tab,
            launchEnabled: false, configuration: configuration)
        tab.externalWorkspaceID = "workspace-1"
        _ = model.addPickerTab()

        let result = try await model.performSessionOperation(
            QuinjetSessionRequest(operation: .focus, session: "1"))

        #expect(result.selectedSessionID == tab.id.uuidString)
        #expect(recorder.values().focused == ["workspace-1"])
        #expect(result.sessions.first?.state == "running")
        #expect(result.sessions.first?.terminal == "cmux")
    }

    @Test func nativeCreateAddsASelectedPickerAndKeepsTheOriginalClosable() async throws {
        let model = QuinjetPageModel(client: client)
        let original = try #require(model.selectedTab)

        let result = try await model.performSessionOperation(
            QuinjetSessionRequest(operation: .create))

        #expect(model.tabs.count == 2)
        #expect(result.operation == .create)
        #expect(result.affectedSessionID == model.selectedTab?.id.uuidString)
        #expect(result.selectedSessionID == model.selectedTab?.id.uuidString)
        #expect(result.sessions.last?.state == "picker")
        #expect(result.sessions.map(\.canClose) == [true, true])

        _ = try await model.performSessionOperation(
            QuinjetSessionRequest(operation: .close, session: original.id.uuidString))
        #expect(model.tabs.count == 1)
        #expect(model.selectedTab?.id == result.affectedSessionID.flatMap(UUID.init(uuidString:)))
    }

    @Test func nativeCloseClosesCMUXBeforeRemovingItsTab() async throws {
        let recorder = QuinjetWorkspaceRecorder()
        let model = QuinjetPageModel(
            client: client,
            focusExternalWorkspace: { recorder.focus($0) },
            closeExternalWorkspace: { recorder.close($0) })
        let tab = try #require(model.selectedTab)
        tab.externalWorkspaceID = "workspace-1"
        let remaining = model.addPickerTab()

        let result = try await model.performSessionOperation(
            QuinjetSessionRequest(operation: .close, session: tab.id.uuidString))

        #expect(recorder.values().closed == ["workspace-1"])
        #expect(result.affectedSessionID == tab.id.uuidString)
        #expect(result.sessions.map(\.id) == [remaining.id.uuidString])
        #expect(result.selectedSessionID == remaining.id.uuidString)
    }

    @Test func nativeSwitchAndRestartReuseTheSameTab() async throws {
        let model = QuinjetPageModel(client: client)
        let tab = try #require(model.selectedTab)
        model.open(
            Self.main, projectName: "edith", available: [Self.main, Self.feature], in: tab,
            launchEnabled: false)

        let switched = try await model.performSessionOperation(
            QuinjetSessionRequest(
                operation: .switchWorktree, session: "1", worktreePath: Self.feature.path))
        let restarted = try await model.performSessionOperation(
            QuinjetSessionRequest(operation: .restart, session: tab.id.uuidString))

        #expect(model.tabs.count == 1)
        #expect(model.selectedTab?.id == tab.id)
        #expect(model.selectedTab?.worktree == Self.feature)
        #expect(switched.affectedSessionID == tab.id.uuidString)
        #expect(restarted.sessions.first?.worktreePath == Self.feature.path)
    }

    @Test func nativeCloseRejectsTheOnlyTab() async throws {
        let model = QuinjetPageModel(client: client)

        await #expect(throws: QuinjetSessionError.lastSession) {
            try await model.performSessionOperation(
                QuinjetSessionRequest(operation: .close, session: "1"))
        }
    }

    @Test func newestLocalProjectRefreshWins() async throws {
        let harness = ProjectRefreshHarness()
        let model = QuinjetPageModel(
            client: QuinjetClient { arguments in try await harness.execute(arguments) })

        let first = Task { await model.refreshProjects() }
        await harness.waitUntilRequested(1)
        let second = Task { await model.refreshProjects() }
        await harness.waitUntilRequested(2)

        await harness.resolve(1, with: try Self.projectData(name: "new"))
        await second.value
        #expect(model.projects.map(\.name) == ["new"])

        await harness.resolve(0, with: try Self.projectData(name: "old"))
        await first.value
        #expect(model.projects.map(\.name) == ["new"])
        #expect(!model.loadingProjects)
        #expect(model.projectError == nil)
    }

    @Test func newestRemoteProjectRefreshWins() async throws {
        let harness = ProjectRefreshHarness()
        let model = QuinjetPageModel(
            client: QuinjetClient { arguments in try await harness.execute(arguments) })
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith.sock", executablePath: "/usr/local/bin/quinjet")

        let first = Task { await model.refreshProjects(for: remote) }
        await harness.waitUntilRequested(1)
        let second = Task { await model.refreshProjects(for: remote) }
        await harness.waitUntilRequested(2)

        await harness.resolve(1, with: try Self.remoteFolderData(path: "/srv/new"))
        await second.value
        #expect(model.projects(for: remote).map(\.name) == ["new"])

        await harness.resolve(0, with: try Self.remoteFolderData(path: "/srv/old"))
        await first.value
        #expect(model.projects(for: remote).map(\.name) == ["new"])
        #expect(!model.isLoadingProjects(for: remote))
        #expect(model.projectError(for: remote) == nil)
    }

    @Test func cancelledProjectRefreshDoesNotApplyItsResult() async throws {
        let harness = ProjectRefreshHarness()
        let model = QuinjetPageModel(
            client: QuinjetClient { arguments in try await harness.execute(arguments) })

        let request = Task { await model.refreshProjects() }
        await harness.waitUntilRequested(1)
        request.cancel()
        await harness.resolve(0, with: try Self.projectData(name: "cancelled"))
        await request.value

        #expect(model.projects.isEmpty)
        #expect(!model.loadingProjects)
        #expect(model.projectError == nil)
    }

    @Test func embeddedLaunchUsesEdithRoutingAndSelectedTheme() throws {
        let configuration = QuinjetLaunchConfiguration(
            terminal: .embedded, theme: .tokyoNight, appearance: .light)

        let request = try QuinjetOperationExecution.launchRequest(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/quinjet"),
            worktreePath: Self.main.path, remote: nil, configuration: configuration,
            managedByEdith: true, localHomeDirectory: "/Users/pulkit")

        #expect(
            request.arguments
                == [
                    "--client", "edith", "-C", "/work/edith", "tui", "--theme",
                    "tokyo-night", "--appearance", "light",
                ])
    }

    @Test func appThemeLaunchSendsCompleteLightAndDarkPalettes() throws {
        let configuration = QuinjetLaunchConfiguration(
            terminal: .embedded, theme: .ayu, appearance: .dark,
            hostTheme: .edith(appTheme: .orange))

        let request = try QuinjetOperationExecution.launchRequest(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/quinjet"),
            worktreePath: Self.main.path, remote: nil, configuration: configuration,
            managedByEdith: true, localHomeDirectory: "/Users/pulkit")
        let marker = try #require(request.arguments.firstIndex(of: "--theme-palette"))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(request.arguments[marker + 1].utf8))
                as? [String: [String: String]])

        #expect(!request.arguments.contains("--theme"))
        #expect(payload["light"]?["background"] == "#f7f3ec")
        #expect(payload["light"]?["accent"] == "#c93400")
        #expect(payload["dark"]?["background"] == "#1a1714")
        #expect(payload["dark"]?["accent"] == "#ff9f0a")
        #expect(request.arguments.suffix(2) == ["--appearance", "dark"])
    }

    @Test func persistedAppThemeAndAppearanceRestoreAHostPalette() throws {
        let name = "QuinjetClientTests.\(UUID().uuidString)"
        let shared = try #require(UserDefaults(suiteName: name))
        let standard = try #require(UserDefaults(suiteName: "\(name).standard"))
        defer {
            shared.removePersistentDomain(forName: name)
            standard.removePersistentDomain(forName: "\(name).standard")
        }
        shared.set(QuinjetThemePreference.app, forKey: AppStorageKeys.Quinjet.theme)
        shared.set(AppTheme.pink.rawValue, forKey: AppStorageKeys.General.theme)
        shared.set("light", forKey: AppStorageKeys.General.appearance)

        let configuration = QuinjetLaunchConfiguration.preferred(
            sharedDefaults: shared, standardDefaults: standard)

        #expect(configuration.appearance == .light)
        #expect(configuration.hostTheme == .edith(appTheme: .pink))
    }

    @Test func cmuxLaunchKeepsRemoteSessionWithoutEdithRouting() throws {
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith socket",
            executablePath: "/home/pulkit/.local/bin/quinjet", distributionID: "ubuntu")
        let configuration = QuinjetLaunchConfiguration(
            terminal: .cmux, theme: .gruvbox, appearance: .dark)

        let request = try QuinjetOperationExecution.launchRequest(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/quinjet"),
            worktreePath: Self.main.path, remote: remote, configuration: configuration,
            managedByEdith: false, localHomeDirectory: "/Users/pulkit")

        #expect(
            request.arguments
                == [
                    "--remote", "pulkit@build", "--ssh-control-path", "/tmp/edith socket",
                    "-C", "/work/edith", "tui", "--theme", "gruvbox", "--appearance", "dark",
                ])
        #expect(!request.arguments.contains("--client"))
        #expect(request.currentDirectory == "/Users/pulkit")
        #expect(
            request.environment
                == ["QUINJET_REMOTE_BINARY": "/home/pulkit/.local/bin/quinjet"])
        #expect(request.shellCommand.contains("exec '/usr/bin/env'"))
        #expect(
            request.shellCommand.contains(
                "'QUINJET_REMOTE_BINARY=/home/pulkit/.local/bin/quinjet'"))
    }

    @Test func WindowsLaunchRunsQuinjetThroughEncodedPowerShell() throws {
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "win-lan", target: "win-lan",
            controlPath: "/tmp/edith socket", platform: .windows,
            homeDirectory: #"C:\Users\kpulk"#,
            executablePath: #"C:\Users\kpulk\scoop\shims\quinjet.exe"#)
        let configuration = QuinjetLaunchConfiguration(
            terminal: .embedded, theme: .gruvbox, appearance: .dark,
            hostTheme: .edith(appTheme: .orange))

        let request = try QuinjetOperationExecution.launchRequest(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/quinjet"),
            worktreePath: #"E:\career\3. MagicAPI\noveum-app-nextjs"#, remote: remote,
            configuration: configuration, managedByEdith: true,
            localHomeDirectory: "/Users/pulkit")

        #expect(request.executableURL.path == "/usr/bin/ssh")
        #expect(
            Array(request.arguments.prefix(5)) == [
                "-tt", "-S", "/tmp/edith socket", "--", "win-lan",
            ])
        let command = try #require(request.arguments.last)
        let payload = try #require(command.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(payload)))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(
            script.contains(
                #"& 'C:\Users\kpulk\scoop\shims\quinjet.exe' '--client' 'edith' '-C'"#))
        #expect(script.contains(#"'E:\career\3. MagicAPI\noveum-app-nextjs'"#))
        #expect(script.contains("'tui' '--theme' 'gruvbox' '--appearance' 'dark'"))
        #expect(request.arguments.count == 6)
        #expect(request.currentDirectory == nil)
    }

    @Test func cmuxCommandQuotesEveryArgument() {
        let command = QuinjetShellCommand.make(
            executable: "/Applications/Quinjet Tools/quinjet",
            arguments: ["-C", "/work/it's ready"])

        #expect(
            command
                == "exec '/Applications/Quinjet Tools/quinjet' '-C' '/work/it'\\''s ready'")
    }

    @Test func cmuxLaunchEscapesAppleScriptText() {
        #expect(
            QuinjetCMUXLauncher.appleScriptQuote("a \"quoted\" folder\n")
                == "\"a \\\"quoted\\\" folder\\n\"")
    }

    @Test func cmuxOperationsLeaveTheMainThread() async throws {
        let ranOnMainThread = try await QuinjetBackgroundOperation.run { Thread.isMainThread }

        #expect(!ranOnMainThread)
    }

    @Test func themeCatalogMatchesQuinjetCapabilities() {
        #expect(
            QuinjetTheme.allCases.map(\.rawValue)
                == [
                    "quinjet", "catppuccin", "dracula", "everforest", "gruvbox", "nord",
                    "one", "rose-pine", "solarized", "tokyo-night", "ayu", "monokai",
                    "github",
                ])
    }

    @Test func appThemesResolveToCompatibleQuinjetThemes() {
        let expected: [AppTheme: QuinjetTheme] = [
            .accent: .quinjet, .blue: .github, .indigo: .tokyoNight,
            .teal: .solarized, .green: .everforest, .purple: .dracula,
            .pink: .rosePine, .red: .monokai, .orange: .ayu,
        ]

        for (appTheme, quinjetTheme) in expected {
            #expect(
                QuinjetThemePreference.resolve(
                    QuinjetThemePreference.app, appTheme: appTheme) == quinjetTheme)
        }
        #expect(
            QuinjetThemePreference.resolve("gruvbox", appTheme: .blue) == .gruvbox)
    }

    @Test func newTabPayloadCreatesAndSelectsPickerTab() async throws {
        let model = QuinjetPageModel(client: client)
        let original = try #require(model.selectedTab)

        model.handleHostPayload("quinjet;open-new-tab", from: original)
        for _ in 0..<20 where model.tabs.count == 1 { await Task.yield() }

        #expect(model.tabs.count == 2)
        #expect(model.selectedTab?.id != original.id)
        #expect(model.selectedTab?.worktree == nil)
    }

    @Test func remoteNewTabPayloadKeepsTheCurrentMachine() async throws {
        let model = QuinjetPageModel(client: client)
        let original = try #require(model.selectedTab)
        let machineID = UUID()
        original.remote = QuinjetRemote(
            machineID: machineID, machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith.sock", executablePath: "/usr/local/bin/quinjet")

        model.handleHostPayload("quinjet;open-new-tab", from: original)
        for _ in 0..<20 where model.tabs.count == 1 { await Task.yield() }

        #expect(model.selectedTab?.machineID == machineID)
        #expect(model.selectedTab?.worktree == nil)
    }

    @Test func worktreePayloadPresentsNativePicker() async throws {
        let model = QuinjetPageModel(client: client)
        let tab = try #require(model.selectedTab)
        model.open(
            Self.main, projectName: "edith", available: [Self.main, Self.feature], in: tab,
            launchEnabled: false)

        model.handleHostPayload("quinjet;open-worktree", from: tab)
        for _ in 0..<20 {
            if tab.showsWorktrees, !tab.loadingWorktrees, tab.worktrees.count == 2 { break }
            await Task.yield()
        }

        #expect(tab.showsWorktrees)
        #expect(tab.worktrees.map(\.branch) == ["main", "feat/quinjet"])
    }

    @Test func selectingWorktreeReusesCurrentTab() throws {
        let model = QuinjetPageModel(client: client)
        let tab = try #require(model.selectedTab)
        model.open(
            Self.main, projectName: "edith", available: [Self.main, Self.feature], in: tab,
            launchEnabled: false)

        model.open(
            Self.feature, projectName: "edith", available: [Self.main, Self.feature], in: tab,
            launchEnabled: false)

        #expect(model.tabs.count == 1)
        #expect(model.selectedTab?.id == tab.id)
        #expect(model.selectedTab?.worktree?.branch == "feat/quinjet")
        #expect(!tab.holder.started)
    }

    @Test func changingTerminalSettingsReconfiguresTheOpenProject() throws {
        let model = QuinjetPageModel(client: client)
        let tab = try #require(model.selectedTab)
        model.open(
            Self.main, projectName: "edith", available: [Self.main, Self.feature], in: tab,
            launchEnabled: false)
        let configuration = QuinjetLaunchConfiguration(
            terminal: .cmux, theme: .dracula, appearance: .light)

        model.apply(configuration, launchEnabled: false)

        #expect(tab.worktree == Self.main)
        #expect(tab.worktrees == [Self.main, Self.feature])
        #expect(tab.launchConfiguration == configuration)
        #expect(!tab.holder.started)
    }

    @Test func changingThemeReconfiguresEveryOpenProjectWithoutChangingSelection() throws {
        let model = QuinjetPageModel(client: client)
        let first = try #require(model.selectedTab)
        model.open(
            Self.main, projectName: "edith", available: [Self.main], in: first,
            launchEnabled: false)
        let second = model.addPickerTab()
        model.open(
            Self.feature, projectName: "edith", available: [Self.feature], in: second,
            launchEnabled: false)
        let selected = try #require(model.selectedTab?.id)
        let configuration = QuinjetLaunchConfiguration(
            terminal: .embedded, theme: .github, appearance: .light,
            hostTheme: .edith(appTheme: .blue))

        model.apply(configuration, launchEnabled: false)

        #expect(model.tabs.allSatisfy { $0.launchConfiguration == configuration })
        #expect(model.selectedTab?.id == selected)
    }

    @Test func terminalRoutesManagedOSCSequence() async {
        let holder = TerminalSessionHolder()
        var action: QuinjetHostAction?
        holder.registerOSCHandler(code: QuinjetHostAction.oscCode) { payload in
            action = QuinjetHostAction(payload: payload)
        }

        holder.consumeManagedOSC(Data("\u{1B}]6973;quinjet;open-new-tab\u{1B}\\".utf8))
        for _ in 0..<10 {
            if action != nil { break }
            await Task.yield()
        }

        #expect(action == .openNewTab)
    }

    @Test func resettingTerminalReleasesTheNativeViewAndQueuedState() {
        let holder = TerminalSessionHolder()
        holder.start(executable: "/bin/cat", arguments: [], environment: [])
        let launch = holder.ghosttyLaunch!
        let original = holder.retainedGhosttyView(
            launch: launch, theme: .init(palette: .edith(dark: true)))
        holder.sendInput("synthetic input")
        holder.reset()
        #expect(holder.ghosttyView == nil && !holder.started && !holder.hasQueuedInput)
        holder.start(executable: "/bin/cat", arguments: [], environment: [])
        let replacement = holder.retainedGhosttyView(
            launch: holder.ghosttyLaunch!, theme: .init(palette: .edith(dark: true)))
        #expect(replacement !== original && holder.generation == 1)
        holder.stop()
    }

    private var client: QuinjetClient {
        let data = (try? JSONEncoder().encode([Self.main, Self.feature])) ?? Data()
        return QuinjetClient { _ in data }
    }

    private static let main = QuinjetWorktree(
        path: "/work/edith", head: "1234567890abcdef", branch: "main", current: true,
        bare: false, detached: false, locked: nil, prunable: nil)
    private static let feature = QuinjetWorktree(
        path: "/work/edith-quinjet", head: "abcdef1234567890", branch: "feat/quinjet",
        current: false, bare: false, detached: false, locked: nil, prunable: nil)

    private static func projectData(name: String) throws -> Data {
        try JSONEncoder().encode([
            QuinjetProject(
                name: name, commonDir: "/work/\(name)/.git",
                worktrees: [
                    QuinjetWorktree(
                        path: "/work/\(name)", head: "1234567890abcdef", branch: "main",
                        current: true, bare: false, detached: false, locked: nil, prunable: nil)
                ])
        ])
    }

    private static func remoteFolderData(path: String) throws -> Data {
        try JSONEncoder().encode(
            QuinjetRemoteFolders(
                remotes: [
                    QuinjetRemoteFolder(
                        target: "pulkit@build", folder: path, accessible: true, uses: 1)
                ]))
    }
}

private actor ProjectRefreshHarness {
    private var requests: [CheckedContinuation<Data, Error>?] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func execute(_ arguments: [String]) async throws -> Data {
        if let marker = arguments.firstIndex(of: "-C"),
            arguments.indices.contains(marker + 1)
        {
            let path = arguments[marker + 1]
            return try JSONEncoder().encode([
                QuinjetWorktree(
                    path: path, head: "1234567890abcdef", branch: "main", current: true,
                    bare: false, detached: false, locked: nil, prunable: nil)
            ])
        }
        return try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            let ready = requestWaiters.filter { requests.count >= $0.0 }
            requestWaiters.removeAll { requests.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitUntilRequested(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func resolve(_ index: Int, with data: Data) {
        guard requests.indices.contains(index), let continuation = requests[index] else { return }
        requests[index] = nil
        continuation.resume(returning: data)
    }
}

private final class QuinjetWorkspaceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var focused: [String] = []
    private var closed: [String] = []

    func focus(_ id: String) {
        lock.lock()
        focused.append(id)
        lock.unlock()
    }

    func close(_ id: String) {
        lock.lock()
        closed.append(id)
        lock.unlock()
    }

    func values() -> (focused: [String], closed: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (focused, closed)
    }
}
