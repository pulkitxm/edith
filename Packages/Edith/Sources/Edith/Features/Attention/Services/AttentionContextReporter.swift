import AppKit
import EdithKit
import Foundation

@MainActor
final class AttentionContextReporter {
    static let shared = AttentionContextReporter()
    static let refresh: TimeInterval = 45

    private var timer: Timer?
    private var last: AttentionAppContext?
    private var sentAt = Date.distantPast
    private var sending = false

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func tick(now: Date = Date()) {
        guard NSApp.isActive, !sending, let bundleID = Bundle.main.bundleIdentifier else { return }
        let context = Self.current(bundleID: bundleID)
        guard context != last || now.timeIntervalSince(sentAt) >= Self.refresh else { return }
        last = context
        sentAt = now
        sending = true
        Task { [weak self] in
            try? await AttentionBackgroundClient.publish(context)
            self?.sending = false
        }
    }

    static func current(bundleID: String) -> AttentionAppContext {
        var tags: [String: String] = [:]
        var parts: [String] = []
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let window, let agentID = HerdrAgentWindow.agentID(of: window) {
            tags[AttentionTag.page] = MainDestination.herdr.rawValue
            tags[AttentionTag.view] = "window"
            parts.append(MainDestination.herdr.title)
            if let agent = HerdrStore.shared.agents.first(where: { $0.id == agentID }) {
                describe(agent, into: &tags, parts: &parts)
            }
        } else if let window, let model = HerdrSpaceWindow.model(of: window) {
            tags[AttentionTag.page] = MainDestination.herdr.rawValue
            tags[AttentionTag.view] = "space"
            parts.append(model.spaceTitle)
            if let agent = model.selectedTab?.agentTab?.agent {
                describe(agent, into: &tags, parts: &parts)
            } else {
                let context = model.selectedContext
                tags[AttentionTag.machine] = context.machineName
                tags[AttentionTag.agent] = HerdrKind.terminalLabel
                if let project = context.workingDirectory.flatMap(AttentionText.project) {
                    tags[AttentionTag.project] = project
                }
                parts.append(context.title)
            }
        } else {
            let stored = SharedDefaults.store.string(forKey: AppStorageKeys.General.mainWindowSection)
            let destination =
                window.flatMap(SectionWindow.destination(of:))
                ?? stored.flatMap(MainDestination.init(rawValue:)) ?? .home
            tags[AttentionTag.page] = destination.rawValue
            parts.append(destination.title)
            switch destination {
            case .herdr:
                if let session = HerdrStore.shared.focusedSession {
                    tags[AttentionTag.view] = session.view.rawValue
                    describe(session.agent, into: &tags, parts: &parts)
                } else {
                    tags[AttentionTag.view] = "board"
                }
            case .machines:
                let machines = MachinesModel.shared
                if let id = machines.selection,
                    let machine = machines.allMachines.first(where: { $0.id == id })
                {
                    tags[AttentionTag.machine] = machine.name
                    parts.append(machine.name)
                }
                if let tab = SharedDefaults.store.string(forKey: AppStorageKeys.Machines.tab) {
                    tags[AttentionTag.view] = tab
                }
            case .docs:
                if let page = DocsBrowser.shared.page {
                    tags[AttentionTag.document] = page.title
                    parts.append(page.title)
                }
            case .settings:
                if let tab = SharedDefaults.store.string(forKey: AppStorageKeys.General.settingsTab)
                {
                    tags[AttentionTag.view] = tab
                }
            default:
                break
            }
        }
        return AttentionAppContext(
            bundleID: bundleID, tags: tags,
            windowTitle: String(parts.joined(separator: " · ").prefix(300)))
    }

    private static func describe(
        _ agent: HerdrAgent, into tags: inout [String: String], parts: inout [String]
    ) {
        tags[AttentionTag.machine] = agent.machineName
        tags[AttentionTag.agent] =
            agent.isTerminal ? HerdrKind.terminalLabel : HerdrKind.displayName(for: agent.kind)
        tags[AttentionTag.session] = agent.id
        if let project = AttentionText.project(agent.cwd) { tags[AttentionTag.project] = project }
        let title = agent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(title.isEmpty ? tags[AttentionTag.agent] ?? "Agent" : title)
        parts.append(agent.machineName)
    }
}
