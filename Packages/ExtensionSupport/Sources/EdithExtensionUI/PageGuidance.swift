import SwiftUI

public struct PageGuideStep: Identifiable, Hashable, Sendable {
    public let symbolName: String
    public let title: String
    public let detail: String
    public var id: String { title }

    public init(symbolName: String, title: String, detail: String) {
        self.symbolName = symbolName
        self.title = title
        self.detail = detail
    }
}

public struct PageAction {
    public let title: String
    public let symbolName: String?
    public let identifier: String?
    public let perform: () -> Void

    public init(
        _ title: String, symbolName: String? = nil, identifier: String? = nil,
        perform: @escaping () -> Void
    ) {
        self.title = title
        self.symbolName = symbolName
        self.identifier = identifier
        self.perform = perform
    }
}

public struct PageEmptyState: View {
    let symbolName: String
    let title: String
    let message: String
    let steps: [PageGuideStep]
    let primary: PageAction?
    let secondary: PageAction?
    let footnote: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    public init(
        symbolName: String, title: String, message: String, steps: [PageGuideStep] = [],
        primary: PageAction? = nil, secondary: PageAction? = nil, footnote: String? = nil
    ) {
        self.symbolName = symbolName
        self.title = title
        self.message = message
        self.steps = steps
        self.primary = primary
        self.secondary = secondary
        self.footnote = footnote
    }

    public var body: some View {
        let dark = scheme == .dark
        VStack(spacing: UIScale.pt(20)) {
            PageGuideBadge(symbolName: symbolName, size: compact ? 52 : 64)
            VStack(spacing: UIScale.pt(8)) {
                Text(title).font(.edithText(.title2)).fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message).font(.edithText(.body)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: UIScale.pt(460))
            if !steps.isEmpty {
                PageGuideSteps(steps: steps, columns: compact ? 1 : min(steps.count, 3))
                    .frame(maxWidth: UIScale.pt(compact ? 460 : 720))
            }
            if primary != nil || secondary != nil {
                HStack(spacing: UIScale.pt(10)) {
                    if let secondary { actionButton(secondary, role: .secondary) }
                    if let primary { actionButton(primary, role: .primary) }
                }
            }
            if let footnote {
                Text(footnote).font(.edithText(.caption)).foregroundStyle(DashSkin.inkFaint(dark))
                    .multilineTextAlignment(.center).frame(maxWidth: UIScale.pt(460))
            }
        }
        .padding(UIScale.pt(compact ? 20 : 32))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func actionButton(_ action: PageAction, role: EdithButtonRole) -> some View {
        Button(action: action.perform) {
            if let symbol = action.symbolName {
                Label(action.title, systemImage: symbol)
            } else {
                Text(action.title)
            }
        }
        .buttonStyle(.edith(role))
        .controlSize(.large)
        .keyboardShortcut(role == .primary ? .defaultAction : nil)
        .accessibilityIdentifier(action.identifier ?? action.title)
    }
}

public struct PageGuideBadge: View {
    let symbolName: String
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    public init(symbolName: String, size: CGFloat = 64) {
        self.symbolName = symbolName
        self.size = size
    }

    public var body: some View {
        let dark = scheme == .dark
        Image(systemName: symbolName)
            .font(.system(size: UIScale.pt(size * 0.42), weight: .medium))
            .foregroundStyle(DashSkin.accent(dark))
            .frame(width: UIScale.pt(size), height: UIScale.pt(size))
            .background(
                DashSkin.accent(dark).opacity(dark ? 0.16 : 0.12),
                in: RoundedRectangle(cornerRadius: UIScale.pt(size * 0.28), style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(size * 0.28), style: .continuous)
                    .strokeBorder(DashSkin.accent(dark).opacity(0.25))
            )
            .accessibilityHidden(true)
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
        let dark = scheme == .dark
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: UIScale.pt(12), alignment: .top),
                count: columns),
            alignment: .leading, spacing: UIScale.pt(12)
        ) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: UIScale.pt(10)) {
                    ZStack {
                        Circle().fill(DashSkin.accent(dark).opacity(0.14))
                        Image(systemName: step.symbolName)
                            .font(.system(size: UIScale.pt(13), weight: .semibold))
                            .foregroundStyle(DashSkin.accent(dark))
                    }
                    .frame(width: UIScale.pt(30), height: UIScale.pt(30))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(step.title).font(.edithText(.callout)).fontWeight(.semibold)
                        Text(step.detail).font(.edithText(.caption)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(UIScale.pt(12))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(DashSkin.line(dark))
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: "Step \(index + 1): \(step.title). \(step.detail)"))
            }
        }
    }
}

public struct PageIntro: View {
    let symbolName: String
    let title: String
    let tagline: String
    let summary: String
    let steps: [PageGuideStep]
    let examples: [String]
    let start: PageAction
    let skip: PageAction?
    let skipAll: PageAction?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    public init(
        symbolName: String, title: String, tagline: String, summary: String,
        steps: [PageGuideStep], examples: [String] = [], start: PageAction,
        skip: PageAction? = nil, skipAll: PageAction? = nil
    ) {
        self.symbolName = symbolName
        self.title = title
        self.tagline = tagline
        self.summary = summary
        self.steps = steps
        self.examples = examples
        self.start = start
        self.skip = skip
        self.skipAll = skipAll
    }

    public var body: some View {
        let dark = scheme == .dark
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(24)) {
                HStack(alignment: .center, spacing: UIScale.pt(16)) {
                    PageGuideBadge(symbolName: symbolName, size: compact ? 52 : 64)
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Text("Welcome to \(title)").font(.edithText(.title)).fontWeight(.bold)
                            .accessibilityAddTraits(.isHeader)
                        Text(tagline).font(.edithText(.title3)).foregroundStyle(.secondary)
                    }
                }
                Text(summary).font(.edithText(.body)).foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    PageSectionHeader("How it works")
                    PageGuideSteps(steps: steps, columns: compact ? 1 : min(steps.count, 2))
                }
                if !examples.isEmpty {
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        PageSectionHeader(
                            "From the terminal or an agent",
                            subtitle: "Every action here is also available through the ed CLI and ed mcp.")
                        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                            ForEach(examples, id: \.self) { example in
                                Text(example).font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(UIScale.pt(12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
                    }
                }
                HStack(spacing: UIScale.pt(10)) {
                    if let skipAll {
                        Button(skipAll.title, action: skipAll.perform).buttonStyle(.edith(.borderless))
                            .accessibilityIdentifier(skipAll.identifier ?? "intro.skip-all")
                    }
                    Spacer()
                    if let skip {
                        Button(skip.title, action: skip.perform).buttonStyle(.edith(.secondary))
                            .controlSize(.large)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier(skip.identifier ?? "intro.skip")
                    }
                    Button(action: start.perform) {
                        Label(start.title, systemImage: start.symbolName ?? "arrow.right")
                    }
                    .buttonStyle(.edith(.primary)).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(start.identifier ?? "intro.start")
                }
            }
            .padding(UIScale.pt(compact ? 20 : 36))
            .frame(maxWidth: UIScale.pt(760), alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
