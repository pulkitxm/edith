import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrUIProjectionTests {
    private func agent(_ id: String) -> HerdrAgent {
        .make(
            machineID: "local", machineName: "Synthetic Mac", machineIsLocal: true,
            sshTarget: nil, session: "fixture", pane: id, kind: "Synthetic tool",
            status: .working, title: id, workspace: "Synthetic space", cwd: "/tmp/fixture")
    }

    private func worker() -> HerdrWorker {
        let defaults = HerdrUIDefaults()
        let store = HerdrStore(defaults: defaults, machinesProvider: { [] })
        store.hosts = [
            .init(
                id: "local", name: "Synthetic Mac", isLocal: true,
                herdrPresent: true, reachable: true, agents: [agent("first"), agent("second")])
        ]
        return HerdrWorker(store: store, defaults: defaults, automaticActions: false)
    }

    @Test func originalDetachedViewPickerMutatesOnlyItsAdmittedEnginePresentation() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = worker()
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let agent = try #require(worker.store.agents.first)
        let presentation = try JSONDecoder().decode(
            HerdrUIPresentation.self,
            from: await client.perform(
                "herdr.ui.present", object: ["kind": "agent", "id": agent.id]))
        _ = try await client.perform(
            "herdr.ui.presentation.admit", object: ["token": presentation.token.uuidString])
        let ui = HerdrStore(uiClient: client)
        try await ui.performUI("herdr.ui.read")
        #expect(ui.detachedTab(id: agent.id)?.view == .agent)
        ui.setView(.split, for: agent.id)
        for _ in 0..<200 {
            if worker.store.detachedTab(id: agent.id)?.view == .split { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(worker.store.detachedTab(id: agent.id)?.view == .split && !worker.store.detailOpen)
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform(
                "herdr.ui.presentation.view", object: ["token": UUID().uuidString, "view": "diff"])
        }
        _ = try await client.perform(
            "herdr.ui.presentation.close", object: ["token": presentation.token.uuidString])
        #expect(worker.store.detachedTab(id: agent.id) == nil)
        await ui.shutdown()
        await worker.shutdown()
    }

    @Test func originalSpaceControlsUseCheckedEngineLayoutAndRejectStaleOrInjectedTargets()
        async throws
    {
        defer { HerdrWorkOwnership.enable() }
        let worker = worker()
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let space = try #require(worker.store.agentSpaces.first)
        let data = try await client.perform(
            "herdr.ui.present", object: ["kind": "space", "id": space.id])
        let presentation = try JSONDecoder().decode(HerdrUIPresentation.self, from: data)
        let ui = HerdrStore(uiClient: client)
        try await ui.performUI("herdr.ui.read")
        let initial = try #require(ui.uiSpaces[space.id])
        #expect(initial.tabs.map(\.agentID) == worker.spaces.openedAgents.map { Optional($0.id) })
        #expect(
            initial.tabs.flatMap(\.holders).allSatisfy {
                $0.terminalLaunch == nil && $0.descriptor == nil
            })
        let baseline = try #require(worker.spaces.uiSpaces.first)
        initial.addTerminal()
        initial.split(.bottom)
        for _ in 0..<200 {
            if worker.spaces.uiSpaces.first?.tabs.count == initial.tabs.count,
                worker.spaces.uiSpaces.first?.tabs.last?.layout.paneCount == 2
            {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let live = try #require(worker.spaces.uiSpaces.first)
        #expect(live.tabs.count == 3 && live.tabs.last?.layout.paneCount == 2)
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform(
                "herdr.ui.space.layout",
                payload: JSONEncoder().encode(
                    HerdrUISpaceMutation(baseline: baseline, space: baseline)))
        }
        var injected = live
        let last = injected.tabs.count - 1
        let paneID = injected.tabs[last].layout.focused
        injected.tabs[last].layout.root.updatePane(paneID) { pane in
            pane.tabs[0].target.argument = "/untrusted-target"
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform(
                "herdr.ui.space.layout",
                payload: JSONEncoder().encode(
                    HerdrUISpaceMutation(baseline: live, space: injected)))
        }
        #expect(worker.spaces.uiSpaces.first == live)
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        _ = TestWindowHost.application
        for width in [760.0, 1180.0] {
            for dark in [false, true] {
                for zoom in [1.0, 1.4] {
                    UIScale.apply(zoom)
                    let host = NSHostingView(
                        rootView: ExtensionPageHost {
                            HerdrSpaceView(model: initial, store: ui, launchEnabled: false)
                                .environment(\.colorScheme, dark ? .dark : .light)
                                .environment(\.automaticViewActionsEnabled, false)
                        })
                    let frame = NSRect(x: 0, y: 0, width: width, height: 760)
                    let window = TestWindowHost.window(contentRect: frame)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    host.frame = frame
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                    #expect(!TestWindowHost.isExposedOnDesktop(window))
                    window.contentView = nil
                    window.close()
                }
            }
        }
        _ = try await client.perform(
            "herdr.ui.presentation.close", object: ["token": presentation.token.uuidString])
        await ui.shutdown()
        await worker.shutdown()
    }

    @Test func originalTerminalSettingsAndSplitPreferencesPersistOnlyInEngine() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = worker()
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let ui = HerdrStore(uiClient: client)
        try await ui.performUI("herdr.ui.read")
        let first = try #require(ui.agents.first)
        ui.open(first)
        ui.saveTerminalSettings(
            .init(
                mouse: .scroll, fontSize: 18, startFolder: .home,
                startupCommand: "printf synthetic", confirmClose: false))
        ui.setSplitFraction(0.7, for: first.id)
        for _ in 0..<200 {
            if worker.store.terminalSettings.fontSize == 18
                && worker.store.splitFraction(for: first.id) == 0.7
            {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(worker.store.terminalSettings == ui.terminalSettings)
        #expect(worker.store.terminalSettings.startupCommand == "printf synthetic")
        #expect(worker.store.splitFraction(for: first.id) == 0.7)
        let state = try #require(try client.state(await client.perform("herdr.ui.read")))
        var forged = state.preferences
        forged[AppStorageKeys.Herdr.terminalFontSize] = .flag(true)
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform(
                "herdr.ui.preferences",
                payload: JSONEncoder().encode(
                    HerdrUIPreferencesMutation(baseline: state.preferences, preferences: forged)))
        }
        #expect(worker.store.terminalSettings.fontSize == 18)
        await ui.shutdown()
        await worker.shutdown()
    }

    @Test func runtimeRejectsUnvalidatedUIAndNeverReturnsAnEnginePage() {
        let runtime = ExtensionRuntime()
        #expect(
            (runtime.execute(["operation": "view", "location": "main"]) as? NSDictionary)?["ok"]
                as? Bool == false)
        #expect(
            (runtime.execute([
                "operation": "configureUI", "location": "main", "remoteUI": true,
                "engineClient": NSObject(),
            ]) as? NSDictionary)?["ok"] as? Bool == false)
        #expect(
            (runtime.execute(["operation": "view", "location": "settings"]) as? NSDictionary)?["ok"]
                as? Bool == false)
    }

    @Test func ownerStopCancelsInflightOriginalCatalogDiscoveryBeforeCommandDrain() async throws {
        defer { HerdrWorkOwnership.enable() }
        let signal = HerdrCatalogCancellationFixture()
        let catalogs = AgentLaunchCatalogs { _, _, _ in
            await signal.started()
            do { try await Task.sleep(for: .seconds(30)) } catch { await signal.cancelled() }
            return nil
        }
        let original = worker()
        let worker = HerdrWorker(
            store: original.store, defaults: original.store.uiDefaults,
            catalogs: catalogs, automaticActions: false)
        let discovery = Task { await catalogs.catalog(for: .codex, refresh: true) }
        for _ in 0..<200 {
            if await signal.didStart { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await signal.didStart)
        await worker.cancelPendingWork()
        #expect(await signal.didCancel)
        _ = await discovery.value
        await worker.shutdown()
    }

    @Test func originalSemanticRankingUsesEngineCandidatesAndRejectsInjectedMeanings() async throws
    {
        defer { HerdrWorkOwnership.enable() }
        let original = worker()
        let worker = HerdrWorker(
            store: original.store, defaults: original.store.uiDefaults,
            searchDecider: { HerdrProjectionDecider() }, automaticActions: false)
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let ids = worker.store.agents.map(\.id)
        let result = try await client.perform(
            "herdr.ui.rank", object: ["query": "second", "agentIDs": ids])
        #expect(try JSONDecoder().decode([String]?.self, from: result) == [ids[1]])
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform(
                "herdr.ui.rank",
                object: [
                    "query": "second", "agentIDs": ids,
                    "meaning": "untrusted replacement",
                ])
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform(
                "herdr.ui.rank", object: ["query": "second", "agentIDs": ["forged"]])
        }
        let model = HerdrSearchModel(
            searcher: { request in
                AgentSearchReply(
                    machineID: request.machineID,
                    hits: request.targets.map {
                        AgentSearchHit(
                            id: $0.id, source: .transcript, title: $0.id, snippet: "synthetic",
                            summary: "synthetic", lastActivity: nil, score: 1)
                    })
            }, decider: { nil }, usage: worker.store.usage,
            ranker: { query, candidates in
                try JSONDecoder().decode(
                    [String]?.self,
                    from: await client.perform(
                        "herdr.ui.rank", object: ["query": query, "agentIDs": candidates.map(\.id)])
                )
            })
        model.query = "second"
        model.search(agents: worker.store.agents, hosts: worker.store.hosts)
        for _ in 0..<200 {
            if model.bestRows.map(\.id) == [ids[1]] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.bestRows.map(\.id) == [ids[1]])
        model.cancel()
        client.stop()
        await worker.shutdown()
    }

    @Test func originalLayoutsAndPreferencesReachOwningEngineWithoutUILaunchPlans() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = worker()
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let ui = HerdrStore(uiClient: client)
        try await ui.performUI("herdr.ui.read")
        let first = try #require(ui.agents.first)
        let second = try #require(ui.agents.last)
        ui.open(first)
        ui.open(second, beside: .right)
        ui.detailOpen = false
        ui.railWidth = 310
        for _ in 0..<200 {
            if worker.store.currentTab?.agentIDs == [first.id, second.id],
                worker.store.railWidth == 310
            {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(worker.store.currentTab?.agentIDs == [first.id, second.id])
        #expect(worker.store.railWidth == 310 && !worker.store.detailOpen)
        #expect(
            ui.sessions.allSatisfy {
                $0.holder.terminalLaunch == nil && $0.holder.descriptor == nil
            })
        ui.toggleZoom(second.id)
        for _ in 0..<200 {
            if worker.store.currentTab?.zoomed == second.id { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(worker.store.currentTab?.zoomed == second.id)
        ui.close(first.id)
        for _ in 0..<200 {
            if worker.store.session(first.id) == nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(worker.store.session(first.id) == nil && worker.store.session(second.id) != nil)
        await ui.shutdown()
        await worker.shutdown()
    }

    @Test func checkedFacadeRejectsUnknownAgentsMalformedLayoutAndDisabledOwner() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = worker()
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let original = try await client.perform("herdr.ui.read")
        let state = try #require(try client.state(original))
        var layout = state.layout
        let forged = agent("forged")
        layout.tabs = [HerdrTab(agentID: forged.id)]
        layout.views = [forged.id: .agent]
        layout.selected = layout.tabs[0].id
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform(
                "herdr.ui.layout",
                payload: JSONEncoder().encode(
                    HerdrUILayoutMutation(baseline: state.layout, layout: layout)))
        }
        #expect(worker.store.tabs.isEmpty)
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform("herdr.ui.read", object: ["executable": "/bin/sh"])
        }
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) { try await client.perform("herdr.ui.read") }
        client.stop()
        #expect(throws: CancellationError.self) { try client.state(original) }
    }

    @Test func originalPanelCreatesOnlyInEngineAndPreservesRunningCloseConfirmation() async throws {
        defer { HerdrWorkOwnership.enable() }
        let backend = HerdrPanelHerdr()
        let defaults = HerdrUIDefaults()
        let panels = HerdrTerminalPanels(defaults: defaults, operations: backend.operations)
        let engineStore = HerdrStore(
            defaults: defaults, machinesProvider: { [] }, terminalPanels: panels)
        engineStore.hosts = [
            .init(
                id: "local", name: "Synthetic Mac", isLocal: true,
                herdrPresent: true, reachable: true, agents: [agent("first")])
        ]
        let worker = HerdrWorker(store: engineStore, defaults: defaults, automaticActions: false)
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let ui = HerdrStore(uiClient: client)
        try await ui.performUI("herdr.ui.read")
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform(
                "herdr.ui.panel",
                object: [
                    "operation": "new", "owner": "board", "machineID": "local",
                    "cwd": "/untrusted-folder",
                ])
        }
        #expect(await backend.openedSessions.isEmpty)
        ui.terminalPanels.newTerminal(in: "board", host: .local, cwd: "~")
        for _ in 0..<200 {
            if panels.terminals.values.first?.process != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await backend.openedSessions == ["default"])
        #expect(await backend.openedDirectories == ["~"])
        let terminal = try #require(panels.terminals.values.first)
        let pane = try #require(terminal.pane)
        await backend.run("synthetic-build", command: "fixture build", in: pane)
        await ui.terminalPanels.refresh("board")
        #expect(ui.terminalPanels.terminals[terminal.id]?.running == true)
        #expect(ui.terminalPanels.terminals[terminal.id]?.holder.terminalLaunch == nil)
        ui.terminalPanels.requestClose(terminal.id)
        for _ in 0..<200 {
            if ui.terminalPanels.closeRequest != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let confirmation = try #require(ui.terminalPanels.closeRequest)
        #expect(confirmation.running == ["synthetic-build"])
        #expect(await backend.closed.isEmpty)
        confirmation.proceed()
        for _ in 0..<200 {
            if await backend.closed == [pane] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await backend.closed == [pane])
        #expect(panels.terminals.isEmpty)
        await ui.shutdown()
        await worker.shutdown()
    }

    @Test func originalHerdrPageRendersOffscreenWithCheckedStateAtBothWidthsZoomAndSchemes()
        async throws
    {
        defer { HerdrWorkOwnership.enable() }
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        let worker = worker()
        for width in [620.0, 1100.0] {
            for dark in [false, true] {
                for zoom in [1.0, 1.4] {
                    UIScale.apply(zoom)
                    let ui = HerdrStore(
                        uiClient: .init { try await worker.execute($0, payload: $1) })
                    try await ui.performUI("herdr.ui.read")
                    let host = NSHostingView(
                        rootView: ExtensionPageHost {
                            HerdrPage(store: ui)
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
                    await ui.shutdown()
                }
            }
        }
        await worker.shutdown()
    }

    @Test func originalProviderPreviewApplyAndBackupAreOwnedByEngine() async throws {
        defer { HerdrWorkOwnership.enable() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AgentActivityHookInstaller(
            home: root, executable: root.appendingPathComponent("Edith"))
        let files = AgentActivityHookFiles(root: root.appendingPathComponent("owner"))
        let defaults = HerdrUIDefaults()
        let monitor = AgentActivityMonitor(defaults: defaults, hookFiles: files)
        let store = HerdrStore(defaults: defaults, machinesProvider: { [] })
        let worker = HerdrWorker(
            store: store, activity: monitor, defaults: defaults,
            activityInstaller: installer, automaticActions: false)
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let ui = AgentActivityMonitor(defaults: HerdrUIDefaults(), uiClient: client)
        let url = installer.configurationURL(provider: .claude, scope: .global)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(
            #"{"permissions":{"allow":["Read(/synthetic)"]},"theme":"synthetic"}"#.utf8)
        try original.write(to: url)
        let (preview, token) = try await ui.prepareHook(
            installer, provider: .claude, scope: .global, enabled: true)
        #expect(preview.original == nil && preview.replacement != nil && token != nil)
        #expect(try Data(contentsOf: url) == original)
        let installation = try await ui.applyHook(
            installer, plan: preview, scope: .global, enabled: true, token: token)
        #expect(installation.changed && installation.url == url)
        let backup = try #require(installation.backupURL)
        #expect(try Data(contentsOf: backup) == original)
        let written =
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(written?["theme"] as? String == "synthetic")
        #expect((written?["permissions"] as? [String: [String]])?["allow"] == ["Read(/synthetic)"])
        await #expect(throws: ExtensionPeerError.self) {
            try await ui.applyHook(
                installer, plan: preview, scope: .global, enabled: true, token: token)
        }
        await ui.save(
            .init(
                providers: ["claude": .init(observing: true, approvals: true)], quietMinutes: 17,
                monitorTerminalAttention: true))
        #expect(
            monitor.settings.configuration(.claude).approvals && monitor.settings.quietMinutes == 17
        )
        await ui.saveMonitoring(discovery: false, stuckMinutes: 120)
        #expect(!monitor.discoversTerminals && monitor.stuckMinutes == 120)
        await ui.shutdown()
        await worker.shutdown()
    }

    @Test func engineHookApplyRejectsChangedFileAndUntrustedReplacement() async throws {
        defer { HerdrWorkOwnership.enable() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AgentActivityHookInstaller(
            home: root, executable: root.appendingPathComponent("Edith"))
        let monitor = AgentActivityMonitor(
            defaults: HerdrUIDefaults(),
            hookFiles: AgentActivityHookFiles(root: root.appendingPathComponent("owner")))
        let worker = HerdrWorker(
            store: HerdrStore(defaults: HerdrUIDefaults(), machinesProvider: { [] }),
            activity: monitor,
            activityInstaller: installer, automaticActions: false)
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let ui = AgentActivityMonitor(defaults: HerdrUIDefaults(), uiClient: client)
        let (plan, token) = try await ui.prepareHook(
            installer, provider: .claude, scope: .global, enabled: true)
        let id = try #require(token)
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform(
                "herdr.ui.hook.apply", object: ["id": id.uuidString, "replacement": "untrusted"])
        }
        try FileManager.default.createDirectory(
            at: plan.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let changed = Data(#"{"theme":"changed-synthetic-policy"}"#.utf8)
        try changed.write(to: plan.url)
        await #expect(throws: AgentActivityHookInstallerError.self) {
            try await ui.applyHook(
                installer, plan: plan, scope: .global, enabled: true, token: token)
        }
        #expect(try Data(contentsOf: plan.url) == changed)
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform(
                "herdr.ui.hook.read", object: ["id": id.uuidString, "offset": 0])
        }
        await ui.shutdown()
    }

    @Test func originalLaunchSettingsUseOwnedCatalogAndPersistOptionsWithoutUIProcesses()
        async throws
    {
        defer { HerdrWorkOwnership.enable() }
        let defaults = HerdrUIDefaults()
        let store = HerdrStore(defaults: defaults, machinesProvider: { [] })
        let catalogs = AgentLaunchCatalogs(fetch: { _, _, _ in nil })
        let worker = HerdrWorker(
            store: store, defaults: defaults, catalogs: catalogs, automaticActions: false)
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let model = HerdrUILaunchSettingsModel(kind: "Claude Code", client: client)
        await model.read()
        #expect(model.ready && model.command == "claude")
        let catalog = try #require(model.catalog)
        let chosen = try #require(catalog.models.first)
        let options = AgentLaunchOptions(
            model: chosen.id, effort: chosen.efforts.first?.id, fast: chosen.supportsFast)
        model.update(command: "fixture-agent --profile synthetic", options: options)
        for _ in 0..<200 {
            if HerdrLaunchSettings.command(for: "Claude Code", in: defaults)
                == "fixture-agent --profile synthetic",
                HerdrLaunchSettings.options(for: "Claude Code", in: defaults) == options
            {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(HerdrLaunchSettings.options(for: "Claude Code", in: defaults) == options)
        #expect(
            HerdrLaunchSettings.command(for: "Claude Code", in: defaults)
                == "fixture-agent --profile synthetic")
        model.reset()
        for _ in 0..<200 {
            if HerdrLaunchSettings.command(for: "Claude Code", in: defaults) == "claude" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(HerdrLaunchSettings.command(for: "Claude Code", in: defaults) == "claude")
        #expect(HerdrLaunchSettings.options(for: "Claude Code", in: defaults) == options)
        let stale = HerdrUILaunchSettingsModel(kind: "Claude Code", client: client)
        await stale.read()
        HerdrLaunchSettings.setCommand("fixture-changed-command", for: "Claude Code", in: defaults)
        stale.update(command: "stale-command")
        for _ in 0..<200 {
            if stale.error != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(
            stale.error != nil
                && HerdrLaunchSettings.command(for: "Claude Code", in: defaults)
                    == "fixture-changed-command"
        )
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform(
                "herdr.ui.launchSettings.read",
                object: ["kind": "Claude Code", "refresh": false, "executable": "/bin/sh"])
        }
        model.shutdown(); stale.shutdown(); client.stop()
        await worker.shutdown()
    }

    @Test func staleLayoutCannotOverwriteOriginalChangesFromAnotherClient() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = worker()
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let data = try await client.perform("herdr.ui.read")
        let original = try #require(try client.state(data))
        let first = try #require(worker.store.agents.first)
        worker.store.open(first)
        let current = worker.store.uiLayout
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform(
                "herdr.ui.layout",
                payload: JSONEncoder().encode(
                    HerdrUILayoutMutation(baseline: original.layout, layout: original.layout)))
        }
        #expect(worker.store.uiLayout == current)
        await worker.shutdown()
    }

    @Test func cancelledProjectionRejectsLateResponseAndOlderSequence() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = worker()
        let first = try await worker.execute("herdr.ui.read", payload: Data("{}".utf8))
        let second = try await worker.execute("herdr.ui.read", payload: Data("{}".utf8))
        var pending: CheckedContinuation<Data, Error>?
        let client = HerdrUIClient { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        #expect(try client.state(second) != nil)
        #expect(try client.state(first) == nil)
        let read = Task { try await client.perform("herdr.ui.read") }
        while pending == nil { await Task.yield() }
        client.stop()
        pending?.resume(returning: second)
        await #expect(throws: CancellationError.self) { try await read.value }
        await worker.shutdown()
    }
}

private struct HerdrProjectionDecider: JevDeciding {
    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        #expect(purpose == AgentSearchJev.purpose)
        guard case .choice(_, let options) = request.questions[AgentSearchJev.question] else {
            throw ExtensionPeerError.invalidRequest
        }
        #expect(options[1].meaning.contains("second"))
        return HerdrDecisionFixture.decision(AgentSearchJev.question, ["s1": 0.9, "s0": 0.1])
    }
}

private actor HerdrCatalogCancellationFixture {
    private(set) var didStart = false
    private(set) var didCancel = false
    func started() { didStart = true }
    func cancelled() { didCancel = true }
}
