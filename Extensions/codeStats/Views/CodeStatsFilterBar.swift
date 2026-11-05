import EdithExtensionSupport
import EdithExtensionUI
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

    static let flags: [(CodeStatsCommitFlags, String, WritableKeyPath<CodeStatsFilter, Bool>)] = [
        (.bulk, "Bulk imports", \.includeBulk),
        (.formatting, "Formatting", \.includeFormatting),
        (.agentAssisted, "Agent-assisted", \.includeAgentAssisted),
        (.coAuthored, "Co-authored", \.includeCoAuthored),
    ]

    var body: some View {
        PageFilterBar {
            PageFilterRow("Range") {
                CodeStatsRangeChips(range: model.range) { range in
                    Task { await model.select(range) }
                }
            }
            PageFilterRow("Filter") {
                facetButton(.repositories, selected: model.filter.repositories.count)
                facetButton(.owners, selected: model.filter.owners.count)
                facetButton(.languages, selected: model.filter.languages.count)
                fileTypesMenu
                countedChangesMenu
                if let note = Self.notCountedNote(model.filter) {
                    Text(note)
                        .font(.edithText(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minHeight: UIScale.pt(PageMetrics.chipHeight))
                        .fixedSize()
                }
                if model.hasActiveFilter {
                    Button("Reset filters") { Task { await model.resetFilter() } }
                        .buttonStyle(.edith(.borderless))
                        .font(PageMetrics.chipFont)
                        .frame(minHeight: UIScale.pt(PageMetrics.chipHeight))
                        .fixedSize()
                }
            }
            if hasSelection {
                PageFilterRow("Showing") { selectedTokens }
            }
        }
    }

    static func notCountedNote(_ filter: CodeStatsFilter) -> String? {
        let excluded = flags.filter { !filter[keyPath: $0.2] }.map { $0.1.lowercased() }
        return excluded.isEmpty ? nil : "Not counted: " + excluded.joined(separator: ", ")
    }

    static func fileTypesTitle(_ categories: Set<CodeStatsCategory>) -> String {
        let selected = CodeStatsCategory.filterable.filter(categories.contains)
        switch selected.count {
        case 0: return "No file types"
        case 1: return selected[0].title
        case CodeStatsCategory.filterable.count: return "All file types"
        default: return "\(selected.count) file types"
        }
    }

    private var countedChangesCustomized: Bool {
        Self.flags.contains {
            model.filter[keyPath: $0.2] != CodeStatsFilter.default[keyPath: $0.2]
        }
    }

    private var hasSelection: Bool {
        let filter = model.filter
        return !filter.repositories.isEmpty || !filter.owners.isEmpty
            || !filter.languages.isEmpty || !filter.excludedRepositories.isEmpty
            || model.isCustomRange
    }

    private var fileTypesMenu: some View {
        PageMenuChip(
            Self.fileTypesTitle(model.filter.categories),
            active: model.filter.categories != CodeStatsFilter.default.categories
        ) {
            Section("Count lines in") {
                ForEach(CodeStatsCategory.filterable, id: \.self) { category in
                    Toggle(
                        category.title,
                        isOn: Binding(
                            get: { model.filter.categories.contains(category) },
                            set: { _ in Task { await model.toggleCategory(category) } }))
                }
            }
        }
        .help("Choose which kinds of files count toward your lines")
    }

    private var countedChangesMenu: some View {
        PageMenuChip("Counted changes", active: countedChangesCustomized) {
            Section("Count toward totals") {
                ForEach(Self.flags, id: \.1) { flag in
                    Toggle(
                        flag.1,
                        isOn: Binding(
                            get: { model.filter[keyPath: flag.2] },
                            set: { value in
                                Task { await model.updateFilter { $0[keyPath: flag.2] = value } }
                            }))
                }
            }
        }
        .help("Choose which kinds of commits count toward your totals")
    }

    private func facetButton(_ kind: CodeStatsFacetKind, selected: Int) -> some View {
        Button {
            open = kind
        } label: {
            PageChipLabel(
                selected == 0
                    ? "All " + kind.rawValue.lowercased() : "\(kind.rawValue) (\(selected))",
                menu: true)
        }
        .buttonStyle(.pageChip(active: selected > 0))
        .fixedSize()
        .popover(
            isPresented: Binding(get: { open == kind }, set: { if !$0 { open = nil } }),
            arrowEdge: .bottom
        ) {
            CodeStatsFacetPicker(model: model, kind: kind, dark: dark)
        }
    }

    @ViewBuilder private var selectedTokens: some View {
        let filter = model.filter
        if model.isCustomRange {
            token(CodeStatsRangeChips.title(model.range)) { await model.clearCustomRange() }
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

    private func token(_ name: String, remove: @escaping () async -> Void) -> some View {
        CodeStatsTokenChip(title: name, active: true) {
            Task { await remove() }
        }
    }
}

struct CodeStatsTokenChip: View {
    let title: String
    var active = false
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: UIScale.pt(6)) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(systemName: "xmark")
                    .font(.system(size: UIScale.pt(8), weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: UIScale.pt(260))
        }
        .buttonStyle(.pageChip(active: active))
        .fixedSize()
        .accessibilityLabel("Remove \(title)")
    }
}

private struct CodeStatsFacetPicker: View {
    let model: CodeStatsModel
    let kind: CodeStatsFacetKind
    let dark: Bool
    @State private var query = ""

    private var facets: [CodeStatsFacet] {
        switch kind {
        case .repositories: model.facets.repositories
        case .owners: model.facets.owners
        case .languages: model.facets.languages
        }
    }

    private var matchingFacets: [CodeStatsFacet] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty
            ? facets : facets.filter { $0.name.localizedCaseInsensitiveContains(query) }
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
            SearchField(placeholder: "Search " + kind.rawValue.lowercased(), text: $query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    ForEach(matchingFacets) { facet in
                        row(facet)
                    }
                    if matchingFacets.isEmpty {
                        ContentUnavailableView.search(text: query)
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
            .font(.edithText(.callout))
            .padding(.vertical, UIScale.pt(4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
    }
}
