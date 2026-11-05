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
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            if model.stage != .finished { stepper }
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
            if let failure = model.failure {
                Text(failure).font(.edithText(.callout)).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .animation(Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: model.stage)
        .padding(UIScale.pt(20))
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
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var stageContent: some View {
        switch model.stage {
        case .welcome: welcome
        case .workflows: workflowChoices
        case .tools: HostOnboardingToolsView(model: model)
        case .permissions: HostOnboardingPermissionsView(model: model)
        case .installing: HostOnboardingInstallView(model: model, progress: progress)
        case .finished: HostOnboardingFinishView(model: model)
        }
    }

    private static let stepTitles = ["Welcome", "Workflow", "Tools", "Permissions", "Install"]

    private var stepper: some View {
        let current = min(model.stage.position, Self.stepTitles.count - 1)
        return HStack(spacing: UIScale.pt(6)) {
            ForEach(Array(Self.stepTitles.enumerated()), id: \.offset) { index, _ in
                Capsule()
                    .fill(index <= current ? DashSkin.accent(dark) : DashSkin.line(dark))
                    .frame(height: UIScale.pt(4))
            }
            Text("Step \(current + 1) of \(Self.stepTitles.count): \(Self.stepTitles[current])")
                .font(.edithText(.caption)).foregroundStyle(.secondary).fixedSize()
                .padding(.leading, UIScale.pt(6))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim:
                    "Setup step \(current + 1) of \(Self.stepTitles.count): \(Self.stepTitles[current])"
            ))
    }

    private var welcome: some View {
        PageIntro(
            symbolName: "sparkles", title: "Edith",
            tagline: "A Mac toolbox you build from small tools.",
            summary:
                "Edith is a set of small, native tools for your Mac, such as usage trackers, clipboard, "
                + "disk cleanup and screen tools. You pick only what you need, and your coding agents can use the same tools.",
            steps: [
                PageGuideStep(
                    symbolName: "square.grid.2x2", title: "Pick what you do",
                    detail: "Choose your workflows and Edith suggests the tools that fit."),
                PageGuideStep(
                    symbolName: "arrow.down.circle", title: "Install only what you want",
                    detail: "Each tool is a small download you can add or remove at any time."),
                PageGuideStep(
                    symbolName: "sidebar.left", title: "Find tools in the sidebar",
                    detail: "Open them from the sidebar, the menu bar, the notch or a hotkey."),
                PageGuideStep(
                    symbolName: "terminal", title: "Let agents drive Edith",
                    detail: "Everything also works through the ed command line and MCP."),
            ],
            examples: ["ed permissions ls", "ed mcp"],
            start: PageAction("Get started", symbolName: "arrow.right", identifier: "onboarding.start") {
                model.start()
            },
            skip: PageAction(model.skipTitle, identifier: "onboarding.skip-all") { model.skip() },
            skipAll: PageAction("Restore from iCloud", identifier: "onboarding.restore") {
                model.restoreSelection()
            }
        )
        .disabled(model.busy)
        .frame(maxHeight: UIScale.pt(560))
    }

    private var workflowChoices: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            PageSectionHeader(
                "What do you do on your Mac?",
                subtitle: "Pick the closest fit. You can fine-tune the tool list on the next step.")
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: compact ? 200 : 240), spacing: UIScale.pt(12))
                ], spacing: UIScale.pt(12)
            ) {
                ForEach(HostWorkflow.allCases) { workflow in
                    Button {
                        model.choose(workflow)
                    } label: {
                        HStack(alignment: .top, spacing: UIScale.pt(12)) {
                            Image(systemName: workflow.symbol).font(.system(size: UIScale.pt(21)))
                                .foregroundStyle(DashSkin.accent(dark)).frame(width: UIScale.pt(28))
                            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                                Text(workflow.title).font(.edithText(.headline))
                                Text(workflow.detail).font(.edithText(.callout))
                                    .foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(
                            maxWidth: .infinity, minHeight: UIScale.pt(72), alignment: .topLeading
                        )
                        .padding(UIScale.pt(12))
                    }
                    .buttonStyle(.edith(model.workflow == workflow ? .primary : .secondary))
                    .disabled(model.busy)
                    .accessibilityLabel(workflow.title)
                    .accessibilityHint(workflow.detail)
                }
            }
            HostOnboardingFooter(
                back: { model.back() },
                skip: PageAction("Skip", identifier: "onboarding.skip-step") { model.skipStep() },
                busy: model.busy)
        }
    }
}

struct HostOnboardingFooter<Leading: View>: View {
    let back: (() -> Void)?
    let skip: PageAction?
    var primary: PageAction?
    var primaryEnabled = true
    var busy = false
    @ViewBuilder var leading: () -> Leading

    init(
        back: (() -> Void)? = nil, skip: PageAction? = nil, primary: PageAction? = nil,
        primaryEnabled: Bool = true, busy: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.back = back
        self.skip = skip
        self.primary = primary
        self.primaryEnabled = primaryEnabled
        self.busy = busy
        self.leading = leading
    }

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            if let back {
                Button("Back", action: back).buttonStyle(.edith(.secondary))
                    .accessibilityIdentifier("onboarding.back").disabled(busy)
            }
            leading()
            Spacer(minLength: 0)
            if let skip {
                Button(skip.title, action: skip.perform).buttonStyle(.edith(.borderless))
                    .accessibilityIdentifier(skip.identifier ?? "onboarding.skip").disabled(busy)
            }
            if let primary {
                Button(action: primary.perform) {
                    if let symbol = primary.symbolName {
                        Label(primary.title, systemImage: symbol)
                    } else {
                        Text(primary.title)
                    }
                }
                .buttonStyle(.edith(.primary))
                .disabled(!primaryEnabled || busy)
                .accessibilityIdentifier(primary.identifier ?? "onboarding.primary")
            }
        }
    }
}

extension HostOnboardingFooter where Leading == EmptyView {
    init(
        back: (() -> Void)? = nil, skip: PageAction? = nil, primary: PageAction? = nil,
        primaryEnabled: Bool = true, busy: Bool = false
    ) {
        self.init(
            back: back, skip: skip, primary: primary, primaryEnabled: primaryEnabled, busy: busy,
            leading: { EmptyView() })
    }
}
