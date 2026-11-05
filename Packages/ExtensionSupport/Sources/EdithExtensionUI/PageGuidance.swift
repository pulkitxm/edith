import EdithIcons
import SwiftUI

public struct PageGuideStep: Identifiable, Hashable, Sendable {
    public let icon: EdithIcon
    public let title: String
    public let detail: String
    public var id: String { title }

    public init(icon: EdithIcon, title: String, detail: String) {
        self.icon = icon
        self.title = title
        self.detail = detail
    }
}

public struct PageAction {
    public let title: String
    public let icon: EdithIcon?
    public let identifier: String?
    public let perform: () -> Void

    public init(
        _ title: String, icon: EdithIcon? = nil, identifier: String? = nil,
        perform: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.identifier = identifier
        self.perform = perform
    }
}

public enum PageEmptyStateStyle: Sendable, Hashable {
    case regular
    case compact
}

public struct PageEmptyState: View {
    let icon: EdithIcon
    let title: String
    let message: String
    let steps: [PageGuideStep]
    let primary: PageAction?
    let secondary: PageAction?
    let footnote: String?
    let style: PageEmptyStateStyle
    let tint: Color?
    var secondaryOnly = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compactLayout

    public init(
        icon: EdithIcon, title: String, message: String, steps: [PageGuideStep] = [],
        primary: PageAction? = nil, secondary: PageAction? = nil, footnote: String? = nil,
        style: PageEmptyStateStyle = .regular, tint: Color? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.steps = steps
        self.primary = primary
        self.secondary = secondary
        self.footnote = footnote
        self.style = style
        self.tint = tint
    }

    init(
        icon: EdithIcon, title: String, message: String, tint: Color?,
        leading: PageAction?, trailing: PageAction?
    ) {
        self.init(
            icon: icon, title: title, message: message, primary: trailing,
            secondary: leading, tint: tint)
        self.secondaryOnly = true
    }

    private var small: Bool { style == .compact }
    private var textWidth: CGFloat { UIScale.pt(small ? 320 : 460) }

    public var body: some View {
        ViewThatFits(in: .vertical) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView { content.frame(maxWidth: .infinity) }
        }
        .accessibilityElement(children: .contain)
    }

    private var content: some View {
        let dark = scheme == .dark
        return VStack(spacing: UIScale.pt(small ? 12 : 20)) {
            PageGuideBadge(
                icon: icon, size: small ? 40 : compactLayout ? 56 : 64, tint: tint)
            VStack(spacing: UIScale.pt(small ? 4 : 8)) {
                Text(title).font(.edithText(small ? .headline : .title2)).fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(message).font(.edithText(small ? .callout : .body)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: textWidth)
            if !small, !steps.isEmpty {
                PageGuideSteps(steps: steps, columns: compactLayout ? 1 : min(steps.count, 3))
                    .frame(maxWidth: UIScale.pt(compactLayout ? 460 : 720))
            }
            if primary != nil || secondary != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) { actions }
                    VStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) { actions }
                }
                .padding(.top, UIScale.pt(small ? 4 : 0))
            }
            if let footnote, !small {
                Text(footnote).font(.edithText(.caption)).foregroundStyle(DashSkin.inkFaint(dark))
                    .multilineTextAlignment(.center).frame(maxWidth: textWidth)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(UIScale.pt(small ? 16 : compactLayout ? 24 : 32))
    }

    @ViewBuilder private var actions: some View {
        if let secondary { actionButton(secondary, role: .secondary) }
        if let primary { actionButton(primary, role: secondaryOnly ? .secondary : .primary) }
    }

    private func actionButton(_ action: PageAction, role: EdithButtonRole) -> some View {
        Button(action: action.perform) {
            if let icon = action.icon {
                Label(action.title, edith: icon)
            } else {
                Text(action.title)
            }
        }
        .buttonStyle(.edith(role))
        .font(.edithText(.body))
        .keyboardShortcut(role == .primary && !small ? .defaultAction : nil)
        .fixedSize()
        .accessibilityIdentifier(action.identifier ?? action.title)
    }
}

public struct PageGuideBadge: View {
    let icon: PageIcon
    var tint: Color?
    @Environment(\.colorScheme) private var scheme

    public init(
        icon: EdithIcon, size: CGFloat = 64, tint: Color? = nil, tone: EdithIconTone = .duotone
    ) {
        self.icon = PageIcon(icon: icon, size: size, tone: tone)
        self.tint = tint
    }

    public init(
        extensionID: String?, icon: EdithIcon, size: CGFloat = 60, tint: Color? = nil,
        tone: EdithIconTone = .duotone
    ) {
        self.icon = PageIcon(
            extensionID: extensionID, icon: icon, size: size, tone: tone)
        self.tint = tint
    }

    public var body: some View {
        icon.foregroundStyle(tint ?? DashSkin.accent(scheme == .dark))
    }

    public func flushLeading() -> some View {
        padding(.leading, -icon.leadingInset)
    }
}

public struct PageGuideSteps: View {
    let steps: [PageGuideStep]
    let columns: Int
    @Environment(\.colorScheme) private var scheme

    public init(steps: [PageGuideStep], columns: Int = 3) {
        self.steps = steps
        self.columns = max(1, columns)
    }

    public var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: UIScale.pt(12), alignment: .top),
                count: columns),
            alignment: .leading, spacing: UIScale.pt(12)
        ) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: UIScale.pt(12)) {
                    PageGuideBadge(icon: step.icon, size: 24)
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(step.title).font(.edithText(.callout)).fontWeight(.semibold)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(step.detail).font(.edithText(.callout)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(UIScale.pt(12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .edithSurface(cornerRadius: 12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    Text(verbatim: "Step \(index + 1): \(step.title). \(step.detail)"))
            }
        }
    }
}

public struct PageIntro: View {
    let extensionID: String?
    let icon: EdithIcon
    let title: String
    let tagline: String
    let summary: String
    let steps: [PageGuideStep]
    let examples: [String]
    let start: PageAction
    let skip: PageAction?
    let skipAll: PageAction?
    let embedded: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    public init(
        icon: EdithIcon, title: String, tagline: String, summary: String,
        steps: [PageGuideStep], examples: [String] = [], start: PageAction,
        skip: PageAction? = nil, skipAll: PageAction? = nil, embedded: Bool = false
    ) {
        self.init(
            extensionID: nil, icon: icon, title: title, tagline: tagline,
            summary: summary, steps: steps, examples: examples, start: start, skip: skip,
            skipAll: skipAll, embedded: embedded)
    }

    public init(
        extensionID: String?, icon: EdithIcon, title: String, tagline: String, summary: String,
        steps: [PageGuideStep], examples: [String] = [], start: PageAction,
        skip: PageAction? = nil, skipAll: PageAction? = nil, embedded: Bool = false
    ) {
        self.extensionID = extensionID
        self.icon = icon
        self.title = title
        self.tagline = tagline
        self.summary = summary
        self.steps = steps
        self.examples = examples
        self.start = start
        self.skip = skip
        self.skipAll = skipAll
        self.embedded = embedded
    }

    public var body: some View {
        if embedded {
            content.frame(maxWidth: .infinity, alignment: .top)
        } else {
            GeometryReader { proxy in
                ScrollView {
                    content.frame(
                        maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                }
            }
        }
    }

    private var content: some View {
        let dark = scheme == .dark
        return VStack(alignment: .leading, spacing: UIScale.pt(24)) {
            HStack(alignment: .center, spacing: UIScale.pt(16)) {
                PageGuideBadge(
                    extensionID: extensionID, icon: icon, size: compact ? 40 : 60
                )
                .flushLeading()
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text("Welcome to \(title)").font(.edithText(.title)).fontWeight(.bold)
                        .accessibilityAddTraits(.isHeader)
                    Text(tagline).font(.edithText(.title3)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(summary).font(.edithText(.body)).foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                PageSectionHeader("How it works")
                PageGuideSteps(
                    steps: steps,
                    columns: compact ? 1 : steps.count % 3 == 0 ? 3 : min(steps.count, 2))
            }
            if !examples.isEmpty {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    PageSectionHeader(
                        "From the terminal or an agent",
                        subtitle:
                            "Every action here is also available through the ed CLI and ed mcp."
                    )
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        ForEach(examples, id: \.self) { example in
                            Text(example).font(.edithText(.callout, design: .monospaced))
                                .foregroundStyle(DashSkin.ink(dark))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(UIScale.pt(12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .edithSurface(cornerRadius: 12)
                }
            }
            HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                if let skipAll {
                    Button(skipAll.title, action: skipAll.perform)
                        .buttonStyle(.edith(.borderless))
                        .font(.edithText(.body))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(skipAll.identifier ?? "intro.skip-all")
                }
                Spacer()
                if let skip {
                    Button(skip.title, action: skip.perform)
                        .buttonStyle(.edith(.secondary))
                        .font(.edithText(.body))
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier(skip.identifier ?? "intro.skip")
                }
                Button(action: start.perform) {
                    Label(start.title, edith: start.icon ?? .arrowRight)
                }
                .buttonStyle(.edith(.primary))
                .font(.edithText(.body))
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(start.identifier ?? "intro.start")
            }
        }
        .padding(UIScale.pt(compact ? 24 : 32))
        .frame(maxWidth: UIScale.pt(760), alignment: .leading)
    }
}
