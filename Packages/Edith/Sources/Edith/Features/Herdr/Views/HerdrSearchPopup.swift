import EdithKit
import SwiftUI

struct HerdrSearchPopup: View {
    let store: HerdrStore
    let open: (HerdrAgent) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage(AppStorageKeys.Presenter.blurAgents, store: SharedDefaults.store) private
        var presenterBlurAgents = true
    private var presenterState = PresenterState.shared
    @State private var model: HerdrSearchModel
    @FocusState private var fieldFocused: Bool

    init(
        store: HerdrStore, model: HerdrSearchModel? = nil,
        open: @escaping (HerdrAgent) -> Void
    ) {
        self.store = store
        self.open = open
        _model = State(initialValue: model ?? HerdrSearchModel())
    }

    private var dark: Bool { scheme == .dark }
    private var hide: Bool { presenterState.active && presenterBlurAgents }
    private var queryTerms: [String] { AgentSearchTerms.terms(model.searchedQuery ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            Divider()
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.danger)
                    .padding(.horizontal, UIScale.pt(14))
                    .padding(.vertical, UIScale.pt(8))
            }
            results
            Divider()
            footer
        }
        .frame(width: UIScale.pt(620), height: UIScale.pt(480))
        .onAppear {
            fieldFocused = true
            model.search(hosts: store.hosts)
        }
        .onDisappear { model.cancel() }
        .onChange(of: model.query) { _, _ in model.queryChanged(hosts: store.hosts) }
    }

    private var field: some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: UIScale.pt(14), weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search agent sessions on every machine…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: UIScale.pt(15)))
                .focused($fieldFocused)
                .disabled(model.resuming)
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    model.move(press.key == .upArrow ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if model.query.isEmpty {
                        dismiss()
                    } else {
                        model.query = ""
                    }
                    return .handled
                }
                .onKeyPress(.return) {
                    if let action = model.submit(hosts: store.hosts) { perform(action) }
                    return .handled
                }
            if model.resuming {
                Text("Resuming…")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.secondary)
            } else if model.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(12))
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    bestSection
                    ForEach(model.sections) { section in
                        sectionHeader(section)
                        sectionBody(section)
                    }
                }
                .padding(.bottom, UIScale.pt(8))
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var bestSection: some View {
        switch model.best {
        case .hidden:
            EmptyView()
        case .ranking:
            header(icon: "sparkles", title: "Best matches", status: "Jev is ranking…")
            HerdrSkeleton(dark: dark, rows: 2, card: false)
                .padding(.horizontal, UIScale.pt(8))
        case .ready(let rows):
            header(icon: "sparkles", title: "Best matches", status: "Picked by Jev")
            ForEach(rows) { row(for: $0, showsMachine: true) }
        case .noMatch:
            header(icon: "sparkles", title: "Best matches", status: "Picked by Jev")
            note("Jev found no session that clearly fits. Keyword matches are below.")
        }
    }

    private func sectionHeader(_ section: HerdrSearchSection) -> some View {
        header(
            icon: section.isLocal ? "laptopcomputer" : "server.rack", title: section.name,
            status: status(section), failed: isFailed(section))
    }

    @ViewBuilder
    private func sectionBody(_ section: HerdrSearchSection) -> some View {
        let rows = model.visibleRows(in: section)
        ForEach(rows) { row(for: $0, showsMachine: false) }
        switch section.state {
        case .searching:
            HerdrSkeleton(dark: dark, rows: rows.isEmpty ? 3 : 1, card: false)
                .padding(.horizontal, UIScale.pt(8))
        case .ready where rows.isEmpty && section.rows.isEmpty:
            note("No matching sessions")
        default:
            EmptyView()
        }
    }

    private func status(_ section: HerdrSearchSection) -> String {
        switch section.state {
        case .searching:
            return "Searching…"
        case .indexing(let pending):
            return "Reading \(pending) more session\(pending == 1 ? "" : "s")…"
        case .ready:
            let count = section.rows.count
            let found = count == 0 ? "No matches" : "\(count) found"
            return section.milliseconds.map { "\(found) · \($0) ms" } ?? found
        case .failed(let message):
            return message
        case .offline:
            return "Offline"
        }
    }

    private func isFailed(_ section: HerdrSearchSection) -> Bool {
        if case .failed = section.state { return true }
        return false
    }

    private func header(icon: String, title: String, status: String, failed: Bool = false)
        -> some View
    {
        HStack(spacing: UIScale.pt(6)) {
            Image(systemName: icon)
                .font(.system(size: UIScale.pt(10), weight: .semibold))
            Text(title.uppercased())
                .font(.system(size: UIScale.pt(10), weight: .semibold))
                .tracking(0.6)
            Spacer(minLength: UIScale.pt(8))
            Text(status)
                .font(.system(size: UIScale.pt(10)))
                .foregroundStyle(failed ? AnyShapeStyle(DashSkin.danger) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, UIScale.pt(14))
        .padding(.top, UIScale.pt(12))
        .padding(.bottom, UIScale.pt(4))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, UIScale.pt(14))
            .padding(.vertical, UIScale.pt(6))
    }

    private func row(for row: HerdrSearchRow, showsMachine: Bool) -> some View {
        let selected = row.id == model.selectedRow?.id
        return Button {
            model.select(row)
            if let action = model.action(for: row) { perform(action) }
        } label: {
            HStack(alignment: .top, spacing: UIScale.pt(10)) {
                HerdrKindMark(kind: row.kind, size: UIScale.pt(15))
                    .padding(.top, UIScale.pt(1))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text(row.title)
                            .font(.system(size: UIScale.pt(12.5), weight: .medium))
                            .lineLimit(1)
                            .presenterTextBlur(hide, fontSize: 12.5)
                        if let agent = row.agent {
                            liveBadge(agent)
                        }
                        Spacer(minLength: 0)
                        if let date = row.hit?.lastActivityDate {
                            Text(date.formatted(.relative(presentation: .named)))
                                .font(.system(size: UIScale.pt(10)))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if !row.snippet.isEmpty {
                        Text(highlighted(row.snippet))
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .presenterTextBlur(hide, fontSize: 11)
                    }
                    Text(detail(row, showsMachine: showsMachine))
                        .font(DashSkin.mono(9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .presenterTextBlur(hide, fontSize: 9.5)
                }
                if selected {
                    Text(row.agent == nil ? "Resume ↩" : "Open ↩")
                        .font(.system(size: UIScale.pt(10), weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, UIScale.pt(1))
                }
            }
            .padding(.horizontal, UIScale.pt(14))
            .padding(.vertical, UIScale.pt(8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.selection, selected: selected))
        .disabled(model.resuming)
        .id(row.id)
        .help(row.agent == nil ? "Resume this session in a new Herdr agent" : "Open this agent")
    }

    private func liveBadge(_ agent: HerdrAgent) -> some View {
        HStack(spacing: UIScale.pt(4)) {
            Circle()
                .fill(HerdrStatusColor.color(agent.status, dark: dark))
                .frame(width: UIScale.pt(6), height: UIScale.pt(6))
            Text(agent.status.title)
                .font(.system(size: UIScale.pt(10)))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, UIScale.pt(6))
        .padding(.vertical, UIScale.pt(1.5))
        .background(Capsule().fill(DashSkin.paper2(dark).opacity(0.8)))
    }

    private func detail(_ row: HerdrSearchRow, showsMachine: Bool) -> String {
        let parts = [row.kind, row.place, showsMachine ? row.hostName : ""]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let terms = queryTerms
        guard !terms.isEmpty else { return result }
        var start = text.startIndex
        while start < text.endIndex {
            guard
                let wordStart = text[start...].firstIndex(where: { $0.isLetter || $0.isNumber })
            else { break }
            let wordEnd =
                text[wordStart...].firstIndex(where: { !($0.isLetter || $0.isNumber) })
                ?? text.endIndex
            if AgentSearchTerms.matches(String(text[wordStart..<wordEnd]), any: terms),
                let lower = AttributedString.Index(wordStart, within: result),
                let upper = AttributedString.Index(wordEnd, within: result)
            {
                result[lower..<upper].foregroundColor = .primary
                result[lower..<upper].font = .system(size: UIScale.pt(11), weight: .semibold)
            }
            start = wordEnd
        }
        return result
    }

    private var footer: some View {
        HStack(spacing: UIScale.pt(12)) {
            Text("↑↓ move   ↩ open   esc close")
            Spacer()
            Text(engineNote)
        }
        .font(.system(size: UIScale.pt(10)))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(8))
    }

    private var engineNote: String {
        if model.usesJev { return "Best matches by Jev · the rest by keywords" }
        return JevAvailability.isConfigured()
            ? "Keyword search" : "Keyword search · add a Jev key in Settings for best matches"
    }

    private func perform(_ action: HerdrSearchAction) {
        switch action {
        case .open(let agent):
            dismiss()
            open(agent)
        case .resume(let hit, let host):
            model.resuming = true
            model.errorMessage = nil
            Task {
                do {
                    try await store.resumeSession(hit, on: host)
                    model.resuming = false
                    dismiss()
                } catch {
                    model.resuming = false
                    model.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
