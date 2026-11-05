import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostGetStartedStep: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case setup, install, permissions, tryTool, agent }
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
            .init(kind: .install, done: input.hasDownloads),
            .init(
                kind: .permissions,
                done: input.permissionsKnown && input.missingPermissions == 0),
            .init(kind: .tryTool, done: input.triedTool),
            .init(kind: .agent, done: input.agentConnected),
        ]
    }

    var completed: Int { steps.filter(\.done).count }
    var next: HostGetStartedStep.Kind? { steps.first { !$0.done }?.kind }
    var progress: String { "\(completed) of \(steps.count) done" }
    var finished: Bool { steps.allSatisfy(\.done) }
    var visible: Bool { permissionsKnown && !dismissed && !finished }
    func step(_ kind: HostGetStartedStep.Kind) -> HostGetStartedStep? {
        steps.first { $0.kind == kind }
    }

    static let agentCommand = "ed mcp install --client all"
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
                PagePanel {
                    header(state)
                } content: {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.steps.enumerated()), id: \.element.id) { index, step in
                            if index > 0 { Divider().opacity(0.6) }
                            row(step, state: state)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("getStarted")
            } else if state.permissionsKnown,
                marketplace.surfaceAvailability.activeIDs.isEmpty
            {
                suggestion
            }
        }
        .pageTask { await permissions.refresh() }
    }

    private var suggestion: some View {
        PagePanel {
            EmptyView()
        } content: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: UIScale.pt(16)) {
                    suggestionText
                    Spacer(minLength: UIScale.pt(8))
                    suggestionAction
                }
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    suggestionText
                    suggestionAction.padding(.leading, UIScale.pt(52))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("getStarted.suggestion")
    }

    private var suggestionText: some View {
        HStack(alignment: .center, spacing: UIScale.pt(12)) {
            PageGuideBadge(symbolName: "puzzlepiece.extension", size: 40)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text("Add live widgets to Home").font(.edithText(.headline))
                Text("Install an extension, like Calendar or Music, and its widget appears here.")
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var suggestionAction: some View {
        Button("Browse extensions", action: openExtensions)
            .buttonStyle(.edith(.primary))
            .font(.edithText(.caption))
            .fixedSize()
            .accessibilityIdentifier("getStarted.browse")
    }

    private func header(_ state: HostGetStarted) -> some View {
        let dark = scheme == .dark
        return VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(12)) {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("Get started").font(.edithText(.headline))
                        .accessibilityAddTraits(.isHeader)
                    Text("A few steps to make Edith yours.").font(.edithText(.callout))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: UIScale.pt(8))
                Text(state.progress).font(.edithText(.caption)).monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Hide") { dismissed = true }
                    .buttonStyle(.edith(.toolbar))
                    .font(.edithText(.caption))
                    .help("Hide this list. Reset it from Settings, General.")
                    .accessibilityIdentifier("getStarted.dismiss")
                    .padding(.trailing, -UIScale.pt(6))
            }
            LoadingProgress(
                value: Double(state.completed), total: Double(state.steps.count),
                tint: DashSkin.accent(dark)
            )
            .accessibilityHidden(true)
        }
    }

    private func row(_ step: HostGetStartedStep, state: HostGetStarted) -> some View {
        let dark = scheme == .dark
        let copy = copy(for: step.kind, state: state)
        let next = state.next == step.kind
        return HStack(alignment: .center, spacing: UIScale.pt(12)) {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(12)) {
                Image(
                    systemName: step.done
                        ? "checkmark.circle.fill" : (next ? "circle.circle" : "circle")
                )
                .font(.system(size: UIScale.pt(15), weight: .medium))
                .foregroundStyle(
                    step.done || next ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)
                )
                .frame(width: UIScale.pt(18))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(copy.title).font(.edithText(.callout)).fontWeight(.medium)
                        .foregroundStyle(
                            step.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Text(copy.detail).font(.edithText(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !step.done, let action = copy.action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.edith(next ? .primary : .secondary))
                    .font(.edithText(.caption))
                    .fixedSize()
                    .accessibilityIdentifier("getStarted." + step.id)
            }
        }
        .padding(.vertical, UIScale.pt(10))
        .frame(minHeight: UIScale.pt(52))
        .accessibilityElement(children: .contain)
        .accessibilityValue(step.done ? "Done" : "Not done")
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
                detail: "Tell Edith how you work and it suggests extensions to install.",
                action: finishSetup.map { PageAction("Continue setup", perform: $0) })
        case .install:
            Copy(
                title: "Install your first extensions",
                detail: "Each extension adds one tool, like a clipboard history or a music player.",
                action: PageAction("Browse extensions", perform: openExtensions))
        case .permissions:
            Copy(
                title: "Grant permissions",
                detail: state.missingPermissions == 1
                    ? "1 permission is needed by an extension you turned on."
                    : state.missingPermissions > 1
                        ? "\(state.missingPermissions) permissions are needed by extensions you turned on."
                        : "Extensions ask for access only when they need it.",
                action: PageAction("Review permissions", perform: openPermissions))
        case .tryTool:
            Copy(
                title: firstTool.map { "Try \($0.title)" } ?? "Try an extension",
                detail: firstTool?.guide?.tagline
                    ?? "Open an installed extension from the sidebar to see what it does.",
                action: firstTool.map { tool in
                    PageAction("Open \(tool.title)") { openExtension(tool.id) }
                })
        case .agent:
            Copy(
                title: "Connect an AI agent",
                detail: copied
                    ? "Copied. Paste it in a terminal to connect every agent on this Mac."
                    : "Let Claude Code, Codex, Cursor or VS Code use your Edith extensions.",
                action: PageAction(copied ? "Copy again" : "Copy setup command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HostGetStarted.agentCommand, forType: .string)
                    copied = true
                    agentConnected = true
                })
        }
    }
}
