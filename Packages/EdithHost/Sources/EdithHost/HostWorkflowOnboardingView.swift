import AppKit
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostWorkflowOnboardingView: View {
    @Bindable var model: HostWorkflowOnboardingModel
    let progress: (String) -> Double
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(24)) {
            if model.stage != .finished { stepper }
            if let failure = model.failure, ![.tools, .installing].contains(model.stage) {
                PageNotice(failure, tone: .warning)
            }
            ZStack(alignment: .topLeading) {
                stageContent
                    .id(model.stage)
                    .transition(
                        Motion.transition(
                            .asymmetric(
                                insertion: .move(edge: model.advancing ? .trailing : .leading)
                                    .combined(with: .opacity),
                                removal: .move(edge: model.advancing ? .leading : .trailing)
                                    .combined(with: .opacity)),
                            reduceMotion: reduceMotion, preferCrossFade: false))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()
        }
        .animation(Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: model.stage)
        .padding(UIScale.pt(compact ? 20 : 24))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(14)).strokeBorder(DashSkin.line(dark)))
        .pageTask(id: model.stage) {
            if model.stage == .permissions {
                await model.watchPermissions()
            } else if [.welcome, .workflows, .tools].contains(model.stage),
                model.catalogRevision == 0, !model.busy
            {
                model.refreshCatalog()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            if model.stage == .permissions { model.refreshPermissions() }
        }
    }

    @ViewBuilder private var stageContent: some View {
        switch model.stage {
        case .welcome: HostOnboardingWelcomeView(model: model)
        case .workflows: HostOnboardingWorkflowsView(model: model)
        case .tools: HostOnboardingToolsView(model: model)
        case .permissions: HostOnboardingPermissionsView(model: model)
        case .installing: HostOnboardingInstallView(model: model, progress: progress)
        case .finished: HostOnboardingFinishView(model: model)
        }
    }

    static let stepTitles = ["Welcome", "Workflow", "Tools", "Permissions", "Install"]

    private var stepper: some View {
        let current = min(model.stage.position, Self.stepTitles.count - 1)
        return VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(4)) {
                Text("Step \(current + 1) of \(Self.stepTitles.count)")
                    .foregroundStyle(.secondary).monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
                Text(Self.stepTitles[current]).fontWeight(.medium)
            }
            .font(.edithText(.caption))
            HStack(spacing: UIScale.pt(4)) {
                ForEach(Self.stepTitles.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= current ? DashSkin.accent(dark) : DashSkin.line(dark))
                        .frame(height: UIScale.pt(4))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim:
                    "Setup step \(current + 1) of \(Self.stepTitles.count): \(Self.stepTitles[current])"
            ))
    }
}

struct HostOnboardingWelcomeView: View {
    @Bindable var model: HostWorkflowOnboardingModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    private var dark: Bool { scheme == .dark }

    static let steps = [
        PageGuideStep(
            symbolName: "square.grid.2x2", title: "Pick a workflow",
            detail: "Tell Edith what you do and it suggests the tools that fit."),
        PageGuideStep(
            symbolName: "checklist", title: "Choose your tools",
            detail: "Each tool is a small download. Add or remove any of them later."),
        PageGuideStep(
            symbolName: "lock.shield", title: "Allow what they need",
            detail: "Approve macOS permissions once, in one place, before you start."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(24)) {
            HStack(alignment: .center, spacing: UIScale.pt(16)) {
                PageGuideBadge(symbolName: "sparkles", size: compact ? 48 : 56)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text("Welcome to Edith").font(.edithText(.title2)).fontWeight(.bold)
                        .accessibilityAddTraits(.isHeader)
                    Text("Small, native tools for your Mac. Pick only the ones you need.")
                        .font(.edithText(.callout)).foregroundStyle(DashSkin.inkSoft(dark))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                Text("Setup takes about a minute").font(.edithText(.headline))
                PageGuideSteps(steps: Self.steps, columns: compact ? 1 : 3)
                Label(
                    "Your coding agents can use every tool too, through the ed command line and MCP.",
                    systemImage: "terminal"
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HostOnboardingFooter(
                skip: PageAction(model.skipTitle, identifier: "onboarding.skip-all") {
                    model.skip()
                },
                primary: PageAction(
                    "Get started", symbolName: "arrow.right", identifier: "onboarding.start"
                ) { model.start() },
                busy: model.busy
            ) {
                Button {
                    model.restoreSelection()
                } label: {
                    Label(
                        model.restoring ? "Restoring from iCloud" : "Restore from iCloud",
                        systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.edith(.borderless))
                .foregroundStyle(DashSkin.accentDeep(dark))
                .disabled(model.busy)
                .help("Bring back the tools and settings you backed up from another Mac.")
                .accessibilityIdentifier("onboarding.restore")
            }
        }
    }
}

struct HostOnboardingWorkflowsView: View {
    @Bindable var model: HostWorkflowOnboardingModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(20)) {
            HostOnboardingStepHeader(
                "What do you mostly do on your Mac?",
                subtitle: "Pick the closest fit. You can add or remove tools on the next step.")
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: UIScale.pt(12), alignment: .top),
                    count: compact ? 2 : 3),
                alignment: .leading, spacing: UIScale.pt(12)
            ) {
                ForEach(HostWorkflow.allCases) { workflow in tile(workflow) }
            }
            HostOnboardingFooter(
                back: { model.back() },
                skip: PageAction("Skip", identifier: "onboarding.skip-step") { model.skipStep() },
                busy: model.busy)
        }
    }

    private func tile(_ workflow: HostWorkflow) -> some View {
        let selected = model.workflow == workflow && !model.selected.isEmpty
        let count = workflow.suggestions(in: model.entries).intersection(model.offeredIDs).count
        return Button {
            model.choose(workflow)
        } label: {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                HStack(alignment: .center) {
                    HostOnboardingIcon(symbolName: workflow.symbol, size: 32)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: UIScale.pt(16)))
                            .foregroundStyle(DashSkin.accent(dark))
                    } else if workflow != .custom, count > 0 {
                        Text("\(count) tools").font(.edithText(.caption))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(workflow.title).font(.edithText(.headline))
                    ZStack(alignment: .topLeading) {
                        Text(verbatim: " ").lineLimit(2, reservesSpace: true).hidden()
                        Text(
                            workflow == .custom
                                ? "Start with nothing ticked and pick each tool yourself."
                                : workflow.detail
                        )
                        .foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        .lineLimit(3)
                    }
                    .font(.edithText(.caption))
                }
            }
            .padding(UIScale.pt(16))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .hostOnboardingTile(highlighted: selected)
            .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(12)))
        }
        .buttonStyle(HostOnboardingTileButtonStyle())
        .disabled(model.busy)
        .accessibilityLabel(workflow.title)
        .accessibilityHint(workflow.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("onboarding.workflow.\(workflow.rawValue)")
    }
}

struct HostOnboardingStepHeader: View {
    let title: String
    let subtitle: String

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(title).font(.edithText(.title3)).fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.edithText(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HostOnboardingIcon: View {
    let symbolName: String
    var size: Double = 32
    var tint: Color?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = tint ?? DashSkin.accent(scheme == .dark)
        Image(systemName: symbolName)
            .font(.system(size: UIScale.pt(size * 0.47), weight: .medium))
            .foregroundStyle(color)
            .frame(width: UIScale.pt(size), height: UIScale.pt(size))
            .background(
                color.opacity(scheme == .dark ? 0.16 : 0.12),
                in: RoundedRectangle(cornerRadius: UIScale.pt(size * 0.28), style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

struct HostOnboardingBadge: View {
    let text: String
    let color: Color

    init(_ text: String, _ color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text).lineLimit(1).fixedSize()
            .font(.edithText(.caption2)).fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, UIScale.pt(8)).padding(.vertical, UIScale.pt(2))
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct HostOnboardingTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HostOnboardingTileButton(configuration: configuration)
    }
}

private struct HostOnboardingTileButton: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(12))
                    .fill(
                        Color.primary.opacity(configuration.isPressed ? 0.06 : hovering ? 0.03 : 0)
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: UIScale.pt(12))
                        .strokeBorder(DashSkin.accent(scheme == .dark), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .opacity(enabled ? 1 : 0.5)
            .onHover { hovering = enabled && $0 }
    }
}

extension View {
    func hostOnboardingTile(highlighted: Bool = false) -> some View {
        modifier(HostOnboardingTile(highlighted: highlighted))
    }
}

private struct HostOnboardingTile: ViewModifier {
    let highlighted: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous)
        content
            .background {
                shape.fill(DashSkin.paper(dark))
                if highlighted { shape.fill(DashSkin.accent(dark).opacity(0.08)) }
            }
            .overlay {
                shape.strokeBorder(
                    highlighted ? DashSkin.accent(dark).opacity(0.7) : DashSkin.line(dark),
                    lineWidth: highlighted ? 1.5 : 1)
            }
    }
}

struct HostOnboardingFooter<Leading: View>: View {
    let back: (() -> Void)?
    let skip: PageAction?
    var primary: PageAction?
    var primaryRole: EdithButtonRole
    var primaryEnabled: Bool
    var busy: Bool
    @ViewBuilder var leading: () -> Leading
    @Environment(\.compactLayout) private var compact

    init(
        back: (() -> Void)? = nil, skip: PageAction? = nil, primary: PageAction? = nil,
        primaryRole: EdithButtonRole = .primary, primaryEnabled: Bool = true, busy: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.back = back
        self.skip = skip
        self.primary = primary
        self.primaryRole = primaryRole
        self.primaryEnabled = primaryEnabled
        self.busy = busy
        self.leading = leading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: UIScale.pt(12)) {
                    backButton
                    leading()
                    Spacer(minLength: UIScale.pt(12))
                    trailing
                }
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    HStack(spacing: UIScale.pt(12)) {
                        Spacer(minLength: 0)
                        trailing
                    }
                    HStack(spacing: UIScale.pt(12)) {
                        backButton
                        leading()
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    @ViewBuilder private var backButton: some View {
        if let back {
            Button(action: back) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.edith(.secondary))
            .accessibilityIdentifier("onboarding.back").disabled(busy)
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: UIScale.pt(16)) {
            if let skip {
                Button(skip.title, action: skip.perform).buttonStyle(.edith(.borderless))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(skip.identifier ?? "onboarding.skip").disabled(busy)
            }
            if let primary {
                Button(action: primary.perform) {
                    if let symbol = primary.symbolName {
                        Label(primary.title, systemImage: symbol)
                            .labelStyle(HostOnboardingTrailingIconLabelStyle())
                    } else {
                        Text(primary.title)
                    }
                }
                .buttonStyle(.edith(primaryRole))
                .keyboardShortcut(primaryRole == .primary ? .defaultAction : nil)
                .disabled(!primaryEnabled || busy)
                .accessibilityIdentifier(primary.identifier ?? "onboarding.primary")
            }
        }
        .fixedSize()
    }
}

struct HostOnboardingTrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: UIScale.pt(6)) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

extension HostOnboardingFooter where Leading == EmptyView {
    init(
        back: (() -> Void)? = nil, skip: PageAction? = nil, primary: PageAction? = nil,
        primaryRole: EdithButtonRole = .primary, primaryEnabled: Bool = true, busy: Bool = false
    ) {
        self.init(
            back: back, skip: skip, primary: primary, primaryRole: primaryRole,
            primaryEnabled: primaryEnabled, busy: busy, leading: { EmptyView() })
    }
}
