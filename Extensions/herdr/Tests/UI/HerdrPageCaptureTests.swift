import AppKit
import EdithExtensionSupport
import EdithExtensionUI
@testable import HerdrUI
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct HerdrPageCaptureTests {
    enum Fixture: String, CaseIterable {
        case loading
        case notInstalled = "not-installed"
        case noAgents = "no-agents"
        case failure
        case populated
        case openAgent = "open-agent"
    }

    struct Variant {
        let name: String
        let size: CGSize
        let dark: Bool
        let compact: Bool
        let scale: Double

        static let all = [
            Variant(
                name: "regular-light", size: CGSize(width: 1100, height: 760), dark: false,
                compact: false, scale: 1),
            Variant(
                name: "regular-dark", size: CGSize(width: 1100, height: 760), dark: true,
                compact: false, scale: 1),
            Variant(
                name: "compact-light", size: CGSize(width: 640, height: 700), dark: false,
                compact: true, scale: 1),
            Variant(
                name: "compact-dark", size: CGSize(width: 640, height: 700), dark: true,
                compact: true, scale: 1),
            Variant(
                name: "zoom-dark", size: CGSize(width: 1100, height: 760), dark: true,
                compact: false, scale: 1.6),
        ]
    }

    @Test(arguments: Fixture.allCases)
    func everyBoardStateFitsRegularCompactAndZoomedWindows(_ fixture: Fixture) async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for variant in Variant.all {
            UIScale.apply(variant.scale)
            let suite = "HerdrPageCaptureTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { UserDefaults().removePersistentDomain(forName: suite) }
            let store = HerdrStore(
                defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
            Self.prepare(store, fixture)
            let drag = HerdrDragCoordinator()
            let host = NSHostingView(
                rootView: AnyView(
                    HerdrPage(store: store, drag: drag)
                        .environment(\.automaticViewActionsEnabled, false)
                        .environment(\.terminalLaunchEnabled, false)
                        .environment(\.compactLayout, variant.compact)
                        .environment(\.colorScheme, variant.dark ? .dark : .light)
                        .environment(\.controlActiveState, .key)
                        .transaction { $0.animation = nil }))
            host.frame = CGRect(origin: .zero, size: variant.size)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
            window.contentView = host
            for _ in 0..<4 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(40))
            }
            #expect(host.fittingSize.width <= variant.size.width)
            #expect(Self.expectedBoard(fixture, store: store))
            #expect(
                (drag.frames[HerdrDropGeometry.sidebarKey] != nil)
                    == (!variant.compact && fixture != .notInstalled))
            try Self.capture(host, name: "herdr-\(fixture.rawValue)-\(variant.name)")
            store.closeAll()
            window.contentView = nil
        }
    }

    enum PopupStep: String, CaseIterable {
        case kind
        case machine
        case space
        case newSpace = "new-space"
        case failure
    }

    @Test(arguments: PopupStep.allCases)
    func theNewAgentStepsExplainThemselvesAtEveryZoom(_ step: PopupStep) async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for (name, dark, scale) in [
            ("light", false, 1.0), ("dark", true, 1.0), ("zoom-dark", true, 1.6),
        ] {
            UIScale.apply(scale)
            let suite = "HerdrPopupCaptureTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { UserDefaults().removePersistentDomain(forName: suite) }
            let store = HerdrStore(
                defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
            let local = HerdrHostSnapshot.local(herdrPresent: true)
            store.apply([
                local,
                HerdrHostSnapshot(
                    id: "8D0B5C1E-0000-4000-8000-000000000001", name: "build-box",
                    isLocal: false, sshTarget: "build-box", herdrPresent: true, reachable: true),
                HerdrHostSnapshot(
                    id: "8D0B5C1E-0000-4000-8000-000000000002", name: "old-laptop",
                    isLocal: false, sshTarget: "old-laptop", herdrPresent: false,
                    reachable: true),
            ])
            let model = store.newAgentPopupModel()
            if step != .kind { model.selectKind(step == .machine ? "Claude Code" : "Codex") }
            if step == .space || step == .newSpace || step == .failure {
                model.selectMachine(local)
                model.workspaces = [
                    HerdrWorkspaceSummary(id: "w1", label: "web-app", tabCount: 2, paneCount: 3),
                    HerdrWorkspaceSummary(id: "w2", label: "billing", tabCount: 1, paneCount: 1),
                ]
            }
            if step == .newSpace { model.spaceQuery = "docs-site" }
            if step == .failure {
                model.errorMessage = "herdr could not create the pane: the session is not running."
            }
            let host = NSHostingView(
                rootView: AnyView(
                    HerdrNewAgentPopup(store: store, model: model)
                        .environment(\.automaticViewActionsEnabled, false)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.controlActiveState, .key)
                        .background(DashSkin.paper(dark))
                        .transaction { $0.animation = nil }))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            for _ in 0..<4 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(40))
            }
            #expect(host.frame.width > 0 && host.frame.height > 0)
            #expect(model.step == (step == .kind ? .kind : step == .machine ? .machine : .space))
            try Self.capture(host, name: "herdr-new-agent-\(step.rawValue)-\(name)")
            store.closeAll()
            window.contentView = nil
        }
    }

    @Test func launchSettingsReadCleanlyAtEveryZoom() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for (name, dark, scale) in [
            ("light", false, 1.0), ("dark", true, 1.0), ("zoom-dark", true, 1.6),
        ] {
            UIScale.apply(scale)
            let suite = "HerdrLaunchCaptureTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { UserDefaults().removePersistentDomain(forName: suite) }
            let store = HerdrStore(
                defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
            let host = NSHostingView(
                rootView: AnyView(
                    HerdrLaunchSettingsSheet(store: store, accounts: store.claudeAccounts)
                        .environment(\.automaticViewActionsEnabled, false)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.controlActiveState, .key)
                        .background(DashSkin.paper(dark))
                        .transaction { $0.animation = nil }))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            for _ in 0..<4 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(40))
            }
            #expect(host.frame.width > 0 && host.frame.height > 0)
            try Self.capture(host, name: "herdr-launch-settings-\(name)")
            window.contentView = nil
        }
    }

    static func expectedBoard(_ fixture: Fixture, store: HerdrStore) -> Bool {
        switch fixture {
        case .loading: return !store.inventoryReceived
        case .notInstalled: return store.hosts.allSatisfy { !$0.herdrPresent }
        case .noAgents: return store.agents.isEmpty && store.machineTerminals.count == 1
        case .failure: return store.inventoryFailureMessage != nil
        case .populated: return store.listedAgents.count == agents.count
        case .openAgent: return store.currentTab?.focused == agents[0].id
        }
    }

    static func prepare(_ store: HerdrStore, _ fixture: Fixture) {
        switch fixture {
        case .loading:
            break
        case .notInstalled:
            store.apply([.local(herdrPresent: false)])
        case .noAgents:
            store.apply([.local(herdrPresent: true)])
        case .failure:
            store.apply([
                .local(
                    herdrPresent: true,
                    error: "The herdr server did not answer within 5 seconds.")
            ])
        case .populated:
            store.apply([.local(herdrPresent: true, agents: agents)])
        case .openAgent:
            store.apply([.local(herdrPresent: true, agents: agents)])
            store.open(agents[0])
        }
    }

    static let agents: [HerdrAgent] = [
        ("Fix the login redirect loop", "Claude Code", HerdrAgentStatus.blocked, "web-app"),
        ("Add CSV export to reports", "Codex", .working, "web-app"),
        ("Write migration for invoices", "Claude Code", .working, "billing"),
        ("Bump dependencies", "Codex", .done, "billing"),
        ("Refactor the settings screen", "Claude Code", .idle, "mobile"),
    ].enumerated().map { index, item in
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "demo", pane: "w\(index + 1):p1", kind: item.1, status: item.2,
            title: item.0, workspace: item.3, cwd: "/Users/demo/\(item.3)")
    }

    static func capture(_ host: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"]
        else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
