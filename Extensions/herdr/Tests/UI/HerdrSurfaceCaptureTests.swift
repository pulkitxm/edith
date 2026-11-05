import AppKit
import EdithExtensionSupport
import EdithExtensionUI
@testable import HerdrUI
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct HerdrSurfaceCaptureTests {
    private static let schemes: [(name: String, dark: Bool, scale: Double)] = [
        ("light", false, 1), ("dark", true, 1), ("zoom-dark", true, 1.6),
    ]

    private func store() throws -> HerdrStore {
        let suite = "HerdrSurfaceCaptureTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = HerdrStore(
            defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        store.apply([.local(herdrPresent: true, agents: HerdrPageCaptureTests.agents)])
        return store
    }

    private func render<V: View>(
        _ name: String, size: CGSize? = nil, @ViewBuilder view: () -> V
    ) async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for scheme in Self.schemes {
            UIScale.apply(scheme.scale)
            let host = NSHostingView(
                rootView: AnyView(
                    view()
                        .environment(\.automaticViewActionsEnabled, false)
                        .environment(\.terminalLaunchEnabled, false)
                        .environment(\.colorScheme, scheme.dark ? .dark : .light)
                        .environment(\.controlActiveState, .key)
                        .background(DashSkin.paper(scheme.dark))
                        .transaction { $0.animation = nil }))
            if let size {
                host.sizingOptions = []
                host.frame = CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: size.width * scheme.scale, height: size.height * scheme.scale))
            } else {
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
            }
            let window = TestWindowHost.window(contentRect: host.frame)
            window.appearance = NSAppearance(named: scheme.dark ? .darkAqua : .aqua)
            window.contentView = host
            for _ in 0..<5 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(40))
            }
            #expect(host.frame.width > 0 && host.frame.height > 0)
            #expect(!TestWindowHost.isExposedOnDesktop(window))
            try HerdrPageCaptureTests.capture(host, name: "\(name)-\(scheme.name)")
            window.contentView = nil
        }
    }

    @Test func searchPopupSeparatesBestMatchesFromSessions() async throws {
        let store = try store()
        let model = HerdrSearchModel(
            searcher: { AgentSearchReply(machineID: $0.machineID) }, decider: { nil })
        try await render("herdr-search-idle") {
            HerdrSearchPopup(store: store, model: model) { _ in }
        }
        model.query = "login"
        model.search(agents: store.listedAgents, hosts: store.hosts)
        try await render("herdr-search-results") {
            HerdrSearchPopup(store: store, model: model) { _ in }
        }
        #expect(model.query == "login")
    }

    @Test func messageSheetExplainsEveryDelivery() async throws {
        let store = try store()
        let recipients = Array(store.listedAgents.prefix(2))
        for delivery in HerdrMessageDraft.Delivery.allCases {
            let messaging = HerdrMessaging(
                broadcaster: { _, _ in [:] }, arm: { _, _, _ in HerdrHooksSnapshot() },
                remove: { _ in HerdrHooksSnapshot() })
            let draft = HerdrMessageDraft(recipients: recipients, delivery: delivery)
            #expect(draft.title == "Message 2 Agents")
            try await render("herdr-message-\(delivery.rawValue)") {
                HerdrMessageSheet(messaging: messaging, draft: draft)
            }
        }
        let single = HerdrMessageDraft(recipients: [recipients[0]], delivery: .now)
        try await render("herdr-message-single") {
            HerdrMessageSheet(messaging: HerdrMessaging(), draft: single)
        }
    }

    @Test func filterMenuListsMachinesKindsAndSpaces() async throws {
        let store = try store()
        #expect(!store.kindChoices.isEmpty)
        try await render("herdr-filter-menu") {
            HerdrFilterMenu(
                store: store, hideAgents: false, onOpenSpace: { _ in }, onEditLaunch: {},
                dismiss: {})
        }
    }

    @Test func layoutPopoverShowsEveryArrangement() async throws {
        let store = try store()
        store.open(HerdrPageCaptureTests.agents[0])
        store.open(HerdrPageCaptureTests.agents[1], beside: .right)
        let tab = try #require(store.currentTab)
        #expect(tab.agentIDs.count == 2)
        try await render("herdr-layout-popover") {
            HerdrLayoutPopover(store: store, tab: tab, hideAgents: false)
        }
        store.closeAll()
    }

    @Test func agentPaneStatesExplainThemselves() async throws {
        let overlays: [(String, HerdrAgentTerminalOverlay)] = [
            ("loading", .progress),
            ("failure", .failure("The herdr server did not answer within 5 seconds.")),
            ("ended", .ended("Session ended with status 1.")),
        ]
        for (name, overlay) in overlays {
            try await render("herdr-agent-pane-\(name)", size: CGSize(width: 560, height: 420)) {
                AgentPanePreview(overlay: overlay)
            }
        }
        #expect(!HerdrAgentTerminalOverlay.failure("x").offersRestart)
        #expect(HerdrAgentTerminalOverlay.ended("x").offersRestart)
    }

    @Test func spaceWindowShowsTabsAndAddingATerminal() async throws {
        let store = try store()
        let agents = Array(HerdrPageCaptureTests.agents.prefix(2))
        let model = HerdrSpaceWindowModel(
            space: HerdrAgentSpace(id: "web-app", title: "web-app", agents: agents), store: store)
        #expect(model.tabs.count == 2)
        try await render("herdr-space-window", size: CGSize(width: 1100, height: 720)) {
            HerdrSpaceView(model: model, store: store, launchEnabled: false)
        }
        let empty = HerdrSpaceWindowModel(
            space: HerdrAgentSpace(id: "empty", title: "empty", agents: []), store: store)
        try await render("herdr-space-empty", size: CGSize(width: 1100, height: 720)) {
            HerdrSpaceView(model: empty, store: store, launchEnabled: false)
        }
    }

    @Test func connectionsPaneListsEveryProvider() async throws {
        let suite = "HerdrConnectionsCapture-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = AgentActivityMonitor(defaults: defaults)
        try await render("herdr-connections", size: CGSize(width: 640, height: 720)) {
            ScrollView { AgentConnectionsPane(monitor: monitor).padding(20) }
        }
    }

    @Test func dragOverlayPreviewsTheDrop() async throws {
        let store = try store()
        store.open(HerdrPageCaptureTests.agents[0])
        let drag = HerdrDragCoordinator()
        drag.store = store
        let canvas = CGRect(x: 0, y: 0, width: 800, height: 520)
        drag.frames[HerdrDropGeometry.canvasKey] = canvas
        drag.update(
            .agent(HerdrPageCaptureTests.agents[1]), at: CGPoint(x: 640, y: 260),
            from: CGPoint(x: 60, y: 60))
        #expect(drag.item != nil)
        try await render("herdr-drag-overlay", size: CGSize(width: 800, height: 520)) {
            HerdrDragOverlay(drag: drag, store: store, hideAgents: false)
        }
        drag.cancel()
    }
}

private struct AgentPanePreview: View {
    let overlay: HerdrAgentTerminalOverlay
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HerdrAgentTerminalOverlayView(
            overlay: overlay, kind: "Claude Code", launchEnabled: true, retry: {}
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: TerminalPalette.edith(dark: scheme == .dark).background))
    }
}
