import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostGetStartedStep: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case setup, permissions, install, tryTool, agent }
    let kind: Kind
    let done: Bool
    var id: String { kind.rawValue }
}

struct HostGetStarted: Equatable {
    struct Input: Equatable {
        var onboardingCompleted: Bool
        var permissionsKnown: Bool
        var missingPermissions: Int
        var hasDownloads: Bool
        var triedTool: Bool
        var agentConnected: Bool
        var dismissed: Bool
    }

    let steps: [HostGetStartedStep]
    let dismissed: Bool
    let permissionsKnown: Bool
    let missingPermissions: Int

    init(_ input: Input) {
        dismissed = input.dismissed
        permissionsKnown = input.permissionsKnown
        missingPermissions = input.missingPermissions
        steps = [
            .init(kind: .setup, done: input.onboardingCompleted),
            .init(
                kind: .permissions,
                done: input.permissionsKnown && input.missingPermissions == 0),
            .init(kind: .install, done: input.hasDownloads),
            .init(kind: .tryTool, done: input.triedTool),
            .init(kind: .agent, done: input.agentConnected),
        ]
    }

    var completed: Int { steps.filter(\.done).count }
    var finished: Bool { steps.allSatisfy(\.done) }
    var visible: Bool { permissionsKnown && !dismissed && !finished }
    func step(_ kind: HostGetStartedStep.Kind) -> HostGetStartedStep? {
        steps.first { $0.kind == kind }
    }

    static let agentCommand = "claude mcp add edith -- ed mcp"
}

struct HostGetStartedCard: View {
    let marketplace: HostMarketplace
    let permissions: HostPermissions
    let defaults: UserDefaults
    let finishSetup: (() -> Void)?
    let openPermissions: () -> Void
    let openExtensions: () -> Void
    let openExtension: (String) -> Void
    @AppStorage(HostSettingsCatalog.onboardingCompletedKey, store: SharedDefaults.store)
    private var onboardingCompleted = false
    @AppStorage(HostSettingsCatalog.getStartedDismissedKey, store: SharedDefaults.store)
    private var dismissed = false
    @AppStorage(HostSettingsCatalog.getStartedTriedKey, store: SharedDefaults.store)
    private var tried = false
    @AppStorage(HostSettingsCatalog.getStartedAgentKey, store: SharedDefaults.store)
    private var agentConnected = false
    @State private var copied = false
    @Environment(\.colorScheme) private var scheme

    init(
        marketplace: HostMarketplace, permissions: HostPermissions, defaults: UserDefaults,
        finishSetup: (() -> Void)?, openPermissions: @escaping () -> Void,
        openExtensions: @escaping () -> Void, openExtension: @escaping (String) -> Void
    ) {
        self.marketplace = marketplace; self.permissions = permissions
        self.defaults = defaults; self.finishSetup = finishSetup
        self.openPermissions = openPermissions; self.openExtensions = openExtensions
        self.openExtension = openExtension
        _onboardingCompleted = AppStorage(
            wrappedValue: false, HostSettingsCatalog.onboardingCompletedKey, store: defaults)
        _dismissed = AppStorage(
            wrappedValue: false, HostSettingsCatalog.getStartedDismissedKey, store: defaults)
        _tried = AppStorage(
            wrappedValue: false, HostSettingsCatalog.getStartedTriedKey, store: defaults)
        _agentConnected = AppStorage(
            wrappedValue: false, HostSettingsCatalog.getStartedAgentKey, store: defaults)
    }

    private var missingPermissions: Int {
        HostPermissionCatalog.usages(
            entries: marketplace.entries, activeIDs: marketplace.surfaceAvailability.activeIDs,
            granted: permissions.granted
        )
        .filter(\.blocksEnabledExtension).count
    }

    private var state: HostGetStarted {
        HostGetStarted(
            .init(
                onboardingCompleted: onboardingCompleted,
                permissionsKnown: !permissions.granted.isEmpty,
                missingPermissions: missingPermissions,
                hasDownloads: !marketplace.downloadedIDs.isEmpty,
                triedTool: tried, agentConnected: agentConnected, dismissed: dismissed))
    }

    private var firstTool: HostExtension? {
        marketplace.entries.first {
            marketplace.surfaceAvailability.navigableIDs.contains($0.id)
                && HostNavigationCatalog.route(extensionID: $0.id) != nil
        }
    }

    var body: some View {
        let state = state
        Group {
            if state.visible {
                PageCard(
                    title: "Get started",
                    note: "\(state.completed) of \(state.steps.count) done"
                ) {
                    VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                        ForEach(state.steps) { row($0, state: state) }
                        HStack {
                            Spacer()
                            Button("Dismiss") { dismissed = true }
                                .buttonStyle(.edith(.borderless))
                                .accessibilityIdentifier("getStarted.dismiss")
                        }
                    }
                }
            }
        }
        .pageTask { await permissions.refresh() }
    }

    private func row(_ step: HostGetStartedStep, state: HostGetStarted) -> some View {
        let dark = scheme == .dark
        let copy = copy(for: step.kind, state: state)
        return HStack(alignment: .center, spacing: UIScale.pt(10)) {
            Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: UIScale.pt(16)))
                .foregroundStyle(step.done ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(copy.title).font(.edithText(.callout)).fontWeight(.medium)
                    .strikethrough(step.done, color: DashSkin.inkFaint(dark))
                Text(copy.detail).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: UIScale.pt(8))
            if !step.done, let action = copy.action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.edith(.secondary))
                    .accessibilityIdentifier("getStarted." + step.id)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private struct Copy {
        let title: String
        let detail: String
        let action: PageAction?
    }

    private func copy(for kind: HostGetStartedStep.Kind, state: HostGetStarted) -> Copy {
        switch kind {
        case .setup:
            Copy(
                title: "Finish setup",
                detail: "Pick the way you work and Edith suggests the tools to download.",
                action: finishSetup.map { PageAction("Finish setup", perform: $0) })
        case .permissions:
            Copy(
                title: "Grant missing permissions",
                detail: state.missingPermissions > 0
                    ? "\(state.missingPermissions) needed by tools you turned on."
                    : "Tools ask for access only when they need it.",
                action: PageAction("Review permissions", perform: openPermissions))
        case .install:
            Copy(
                title: "Install your first tools",
                detail: "Edith is built from downloadable tools. Choose the ones you want.",
                action: PageAction("Browse tools", perform: openExtensions))
        case .tryTool:
            Copy(
                title: firstTool.map { "Try \($0.title)" } ?? "Try one of your tools",
                detail: firstTool?.guide?.tagline
                    ?? "Open any installed tool from the sidebar to see what it does.",
                action: firstTool.map { tool in
                    PageAction("Open \(tool.title)") { openExtension(tool.id) }
                })
        case .agent:
            Copy(
                title: "Connect an agent",
                detail: copied
                    ? "Copied. Run it in a terminal to let Claude Code drive Edith over MCP."
                    : "Let Claude Code or Codex use every Edith tool through ed mcp.",
                action: PageAction(copied ? "Copy again" : "Copy setup command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HostGetStarted.agentCommand, forType: .string)
                    copied = true
                    agentConnected = true
                })
        }
    }
}
