import EdithKit
import EdithStudio
import SwiftUI

enum StudioToolFilter: Hashable {
    case all
    case family(StudioKind)
    case intelligence

    var title: String {
        switch self {
        case .all: "All"
        case let .family(kind): kind == .document ? "Documents & web" : kind.pluralTitle
        case .intelligence: "Intelligence"
        }
    }

    static var available: [StudioToolFilter] {
        [.all] + StudioToolCatalogQuery.families().map { .family($0) } + [.intelligence]
    }
}

enum StudioToolCatalogQuery {
    static func families() -> [StudioKind] {
        let order: [StudioKind] = [.pdf, .image, .video, .audio, .document, .archive]
        let present = Set(StudioCatalog.tools.filter { $0.group != .intelligence }.map(\.family))
        return order.filter(present.contains)
    }

    static func tools(filter: StudioToolFilter, query: String) -> [StudioTool] {
        StudioCatalog.tools.filter { tool in
            guard tool.matches(query) else { return false }
            switch filter {
            case .all: return true
            case let .family(kind): return tool.family == kind && tool.group != .intelligence
            case .intelligence: return tool.group == .intelligence
            }
        }
    }
}

struct StudioToolsView: View {
    let model: StudioModel
    @State private var filter: StudioToolFilter = .all
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        let tools = StudioToolCatalogQuery.tools(filter: filter, query: model.toolQuery)
        let groups = StudioToolGrouping.byGroup(tools)
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                HStack(spacing: UIScale.pt(10)) {
                    HStack(spacing: UIScale.pt(6)) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(
                            "Search tools",
                            text: Binding(get: { model.toolQuery }, set: { model.toolQuery = $0 })
                        )
                        .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, UIScale.pt(10))
                    .padding(.vertical, UIScale.pt(6))
                    .frame(maxWidth: UIScale.pt(260))
                    .background(
                        DashSkin.paper2(scheme == .dark),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: UIScale.pt(8)).strokeBorder(
                            DashSkin.line(scheme == .dark)))
                    ScrollView(.horizontal) {
                        HStack(spacing: UIScale.pt(6)) {
                            ForEach(StudioToolFilter.available, id: \.self) { option in
                                StudioChip(title: option.title, selected: filter == option) {
                                    filter = option
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
                if filter == .all, model.toolQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    StudioWorkflowSection(model: model)
                }
                if groups.isEmpty {
                    Text("No tools match \"\(model.toolQuery)\".")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, UIScale.pt(40))
                }
                ForEach(groups, id: \.group) { entry in
                    VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                        Text(entry.group.title.uppercased())
                            .font(DashSkin.mono(10, weight: .semibold))
                            .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: UIScale.pt(240)), spacing: UIScale.pt(12))
                            ],
                            alignment: .leading, spacing: UIScale.pt(12)
                        ) {
                            ForEach(entry.tools) { tool in
                                StudioToolCard(tool: tool, environment: model.environment) {
                                    model.open(tool, with: model.selectedURLs)
                                }
                            }
                        }
                    }
                }
            }
            .pageContent(compact)
        }
        .scrollIndicators(.automatic)
    }
}

struct StudioToolCard: View {
    let tool: StudioTool
    let environment: StudioEnvironment
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack(alignment: .top) {
                    StudioToolIcon(tool: tool, size: 36)
                    Spacer()
                    StudioToolBadges(tool: tool, environment: environment)
                }
                Text(tool.title)
                    .font(.system(size: UIScale.pt(13.5), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(scheme == .dark))
                Text(tool.summary)
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkSoft(scheme == .dark))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(UIScale.pt(14))
            .frame(maxWidth: .infinity, minHeight: UIScale.pt(138), alignment: .topLeading)
            .background(
                DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(12))
                    .strokeBorder(
                        hovering
                            ? StudioPalette.tint(for: tool).opacity(0.6)
                            : DashSkin.line(scheme == .dark))
            )
            .offset(y: hovering ? -1 : 0)
            .shadow(color: .black.opacity(hovering ? 0.08 : 0), radius: 6, y: 3)
            .edithButtonTarget(.borderless)
        }
        .buttonStyle(.edith(.borderless))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.summary)
    }
}

struct StudioToolBadges: View {
    let tool: StudioTool
    let environment: StudioEnvironment

    var body: some View {
        HStack(spacing: UIScale.pt(4)) {
            if case .editor = tool.style {
                badge("Editor", color: .secondary)
            }
            if tool.style == .compare { badge("Viewer", color: .secondary) }
            ForEach(environment.missing(for: tool), id: \.self) { requirement in
                badge("Needs \(requirement.title)", color: DashSkin.warn)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: UIScale.pt(9.5), weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, UIScale.pt(6))
            .padding(.vertical, UIScale.pt(2))
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct StudioToolRow: View {
    let tool: StudioTool
    let environment: StudioEnvironment
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(10)) {
                StudioToolIcon(tool: tool, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.title)
                        .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                        .foregroundStyle(DashSkin.ink(scheme == .dark))
                    Text(tool.summary)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(UIScale.pt(10))
            .background(
                DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(10)).strokeBorder(
                    DashSkin.line(scheme == .dark))
            )
            .edithButtonTarget(.borderless)
        }
        .buttonStyle(.edith(.borderless))
    }
}
