import EdithKit
import SwiftUI

struct CodeStatsActions {
    var toggleRepository: (String) -> Void = { _ in }
    var excludeRepository: (String) -> Void = { _ in }
    var toggleLanguage: (String) -> Void = { _ in }
    var toggleOwner: (String) -> Void = { _ in }
    var zoom: (Date, Date) -> Void = { _, _ in }
    var dayDetails: [String: CodeStatsDayDetail] = [:]
    var selectedRepositories: Set<String> = []
    var selectedLanguages: Set<String> = []
}

private struct CodeStatsActionsKey: EnvironmentKey {
    static let defaultValue = CodeStatsActions()
}

extension EnvironmentValues {
    var codeStatsActions: CodeStatsActions {
        get { self[CodeStatsActionsKey.self] }
        set { self[CodeStatsActionsKey.self] = newValue }
    }
}

enum CodeStatsFacetKind: String, Identifiable {
    case repositories = "Repositories"
    case owners = "Owners"
    case languages = "Languages"

    var id: String { rawValue }
}

struct CodeStatsFilterBar: View {
    let model: CodeStatsModel
    let dark: Bool
    @State private var open: CodeStatsFacetKind?

    private static let flags:
        [(CodeStatsCommitFlags, String, WritableKeyPath<CodeStatsFilter, Bool>)] = [
            (.bulk, "Bulk imports", \.includeBulk),
            (.formatting, "Formatting", \.includeFormatting),
            (.agentAssisted, "Agent-assisted", \.includeAgentAssisted),
            (.coAuthored, "Co-authored", \.includeCoAuthored),
        ]

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(10)) {
                CodeStatsRangePicker(range: model.range) { range in
                    Task { await model.select(range) }
                }
                if model.isComputing {
                    ProgressView().controlSize(.small)
                }
                if let dominant = model.explorer.dominant,
                    !model.filter.excludedRepositories.contains(dominant.repository),
                    model.filter.repositories.isEmpty
                {
                    Button {
                        Task { await model.toggleExcludedRepository(dominant.repository) }
                    } label: {
                        AttentionChip(
                            title:
                                "Exclude \(dominant.repository) (\(CodeStatsNumberFormat.percent(dominant.share * 100)) of lines)",
                            color: DashSkin.warn, active: false)
                    }
                    .buttonStyle(.edith(.borderless))
                    .help(
                        "One repository dominates this range. Exclude it to see the rest clearly.")
                }
                Spacer()
                if model.hasActiveFilter {
                    Button("Reset filters") { Task { await model.resetFilter() } }
                        .buttonStyle(.edith(.borderless))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(6)) {
                    facetButton(.repositories, selected: model.filter.repositories.count)
                    facetButton(.owners, selected: model.filter.owners.count)
                    facetButton(.languages, selected: model.filter.languages.count)
                    separator
                    ForEach(CodeStatsCategory.filterable, id: \.self) { category in
                        let active = model.filter.categories.contains(category)
                        Button {
                            Task { await model.toggleCategory(category) }
                        } label: {
                            AttentionChip(
                                title: category.title, color: DashSkin.accent(dark), active: active)
                        }
                        .buttonStyle(.edith(.borderless))
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                    separator
                    ForEach(Self.flags, id: \.1) { flag in
                        let active = model.filter[keyPath: flag.2]
                        Button {
                            Task { await model.updateFilter { $0[keyPath: flag.2].toggle() } }
                        } label: {
                            AttentionChip(
                                title: flag.1, color: DashPalette.slate(dark), active: active)
                        }
                        .buttonStyle(.edith(.borderless))
                        .help(active ? "Counted. Click to exclude." : "Excluded. Click to count.")
                    }
                }
                .padding(.vertical, UIScale.pt(2))
            }
            selectedTokens
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(DashSkin.lineStrong(dark))
            .frame(width: UIScale.pt(1), height: UIScale.pt(16))
    }

    private func facetButton(_ kind: CodeStatsFacetKind, selected: Int) -> some View {
        Button {
            open = kind
        } label: {
            AttentionChip(
                title: selected == 0
                    ? "All " + kind.rawValue.lowercased() : "\(kind.rawValue) (\(selected))",
                color: DashSkin.accent(dark), active: selected > 0)
        }
        .buttonStyle(.edith(.borderless))
        .popover(
            isPresented: Binding(get: { open == kind }, set: { if !$0 { open = nil } }),
            arrowEdge: .bottom
        ) {
            CodeStatsFacetPicker(model: model, kind: kind, dark: dark)
        }
    }

    @ViewBuilder private var selectedTokens: some View {
        let filter = model.filter
        if !filter.repositories.isEmpty || !filter.owners.isEmpty || !filter.languages.isEmpty
            || !filter.excludedRepositories.isEmpty || model.isCustomRange
        {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(6)) {
                    if model.isCustomRange {
                        token(CodeStatsRangePicker.title(model.range)) {
                            await model.clearCustomRange()
                        }
                    }
                    ForEach(filter.excludedRepositories.sorted(), id: \.self) { name in
                        token("Excluding " + name) { await model.toggleExcludedRepository(name) }
                    }
                    ForEach(filter.owners.sorted(), id: \.self) { name in
                        token(name) { await model.toggleOwner(name) }
                    }
                    ForEach(filter.repositories.sorted(), id: \.self) { name in
                        token(name) { await model.toggleRepository(name) }
                    }
                    ForEach(filter.languages.sorted(), id: \.self) { name in
                        token(name) { await model.toggleLanguage(name) }
                    }
                }
            }
        }
    }

    private func token(_ name: String, remove: @escaping () async -> Void) -> some View {
        Button {
            Task { await remove() }
        } label: {
            HStack(spacing: UIScale.pt(4)) {
                Text(name).lineLimit(1)
                Image(systemName: "xmark.circle.fill")
            }
            .font(.system(size: UIScale.pt(11), weight: .medium))
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(3))
            .background(DashSkin.accent(dark).opacity(0.16), in: Capsule())
            .foregroundStyle(DashSkin.ink(dark))
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel("Remove filter \(name)")
    }
}

private struct CodeStatsFacetPicker: View {
    let model: CodeStatsModel
    let kind: CodeStatsFacetKind
    let dark: Bool
    @State private var query = ""

    private static let limit = 400

    private var facets: [CodeStatsFacet] {
        switch kind {
        case .repositories: model.facets.repositories
        case .owners: model.facets.owners
        case .languages: model.facets.languages
        }
    }

    private var selected: Set<String> {
        switch kind {
        case .repositories: model.filter.repositories
        case .owners: model.filter.owners
        case .languages: model.filter.languages
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            TextField("Search " + kind.rawValue.lowercased(), text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    ForEach(facets.prefix(Self.limit)) { facet in
                        if query.isEmpty || facet.name.localizedCaseInsensitiveContains(query) {
                            row(facet)
                        }
                    }
                }
            }
            .frame(height: UIScale.pt(320))
            if !selected.isEmpty {
                Button("Clear " + kind.rawValue.lowercased()) {
                    Task {
                        await model.updateFilter { filter in
                            switch kind {
                            case .repositories: filter.repositories = []
                            case .owners: filter.owners = []
                            case .languages: filter.languages = []
                            }
                        }
                    }
                }
                .buttonStyle(.edith(.borderless))
            }
        }
        .padding(UIScale.pt(12))
        .frame(width: UIScale.pt(340))
    }

    private func row(_ facet: CodeStatsFacet) -> some View {
        let isOn = selected.contains(facet.name)
        return Button {
            Task {
                switch kind {
                case .repositories: await model.toggleRepository(facet.name)
                case .owners: await model.toggleOwner(facet.name)
                case .languages: await model.toggleLanguage(facet.name)
                }
            }
        } label: {
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                Text(facet.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer()
                Text(CodeStatsNumberFormat.compact(facet.commits) + " commits")
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .monospacedDigit()
            }
            .font(.system(size: UIScale.pt(12)))
            .padding(.vertical, UIScale.pt(4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
    }
}
