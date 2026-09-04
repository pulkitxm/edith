import EdithKit
import SwiftUI

struct SEOAuditProjectView: View {
    private static let inactiveProject = SEOAuditProject(name: "Site Audit", baseURL: "")

    @Bindable var model: SEOAuditModel
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @State private var expandedPages = Set<UUID>()
    @State private var confirmsDeletion = false
    @State private var pageSelectionPresented = false
    @State private var backHovered = false

    private var dark: Bool { scheme == .dark }
    private var project: SEOAuditProject {
        model.selectedProject ?? Self.inactiveProject
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.isRunning {
                SEOAuditProgressRail(stage: model.stage, progress: model.selectedRun?.progress ?? 0)
                    .padding(.horizontal, PageMetrics.gutter(compact))
                    .padding(.bottom, UIScale.pt(14))
            }
            Divider()
            ScrollView {
                LazyVStack(
                    alignment: .leading, spacing: UIScale.pt(16),
                    pinnedViews: [.sectionHeaders]
                ) {
                    summary
                    commandDeck
                    Section {
                        pageList
                    } header: {
                        pinnedControls
                    }
                }
                .pageContent(compact)
                .padding(.top, UIScale.pt(16))
            }
        }
        .confirmationDialog(
            "Delete \(project.name)?", isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                Task { await model.deleteSelectedProject() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved run and page result for this project will be removed from this Mac.")
        }
        .sheet(isPresented: $pageSelectionPresented) {
            SEOAuditPageSelectionSheet(model: model)
        }
        .onChange(of: model.selectedRunID) { _, _ in expandedPages.removeAll() }
    }

    private var toolbar: some View {
        HStack(spacing: UIScale.pt(12)) {
            Button(action: model.closeProject) {
                Image(systemName: "chevron.left")
                    .frame(width: UIScale.pt(30), height: UIScale.pt(30))
            }
            .buttonStyle(.edith(.toolbar))
            .background(
                backHovered ? DashSkin.paper2(dark) : .clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(8))
                    .strokeBorder(
                        backHovered ? DashSkin.accent(dark).opacity(0.45) : .clear,
                        lineWidth: UIScale.pt(1))
            )
            .onHover { backHovered = $0 }
            .animation(.easeOut(duration: 0.14), value: backHovered)
            .help(model.isRunning ? "View projects while this audit continues" : "Back to projects")
            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                Text(project.name)
                    .font(.system(size: UIScale.pt(16), weight: .semibold))
                Text(project.baseURL)
                    .font(DashSkin.mono(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.isRunning {
                Button("Stop", role: .destructive, action: model.cancel)
            } else {
                Button(action: model.leaveForNewProject) {
                    Label("New project", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            Menu {
                Button("Delete Project", role: .destructive) { confirmsDeletion = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: UIScale.pt(24), height: UIScale.pt(24))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.isRunning)
        }
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.vertical, UIScale.pt(14))
    }

    private var summary: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: UIScale.pt(compact ? 125 : 160)), spacing: UIScale.pt(10))
            ],
            spacing: UIScale.pt(10)
        ) {
            metric(
                "Pages", model.selectedRun.map { String($0.pages.count) } ?? "0", "in this run",
                "doc.on.doc")
            metric(
                "Issues", model.selectedRun.map { String($0.issueCount) } ?? "0",
                "across all pages", "exclamationmark.triangle")
            metric(
                "Average", model.selectedRun?.averageScore.map(String.init) ?? "—",
                "Lighthouse score", "gauge.with.needle")
            metric(
                "Runs", String(project.runs.count), "saved locally",
                "clock.arrow.trianglehead.counterclockwise.rotate.90")
        }
    }

    private func metric(_ title: String, _ value: String, _ detail: String, _ icon: String)
        -> some View
    {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack {
                Text(title)
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon).foregroundStyle(DashSkin.accent(dark))
            }
            Text(value).font(DashSkin.mono(25, weight: .semibold))
            Text(detail).font(.system(size: UIScale.pt(10))).foregroundStyle(.tertiary)
        }
        .padding(UIScale.pt(14))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(12))
                .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1)))
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UIScale.pt(10)) {
                if !project.runs.isEmpty { runPicker }
                filters
            }
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                if !project.runs.isEmpty { runPicker }
                filters
            }
        }
    }

    private var pinnedControls: some View {
        controls
            .padding(.vertical, UIScale.pt(9))
            .background(DashSkin.paper(dark))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DashSkin.line(dark))
                    .frame(height: UIScale.pt(1))
            }
            .zIndex(1)
    }

    private var commandDeck: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("AUDIT COMMANDS")
                        .font(DashSkin.mono(8.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(DashSkin.accent(dark))
                    Text("Discover, choose, then audit")
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                }
                Spacer()
                if !model.lighthouseAvailable {
                    Label("Lighthouse is not on PATH", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: UIScale.pt(10), weight: .medium))
                        .foregroundStyle(DashSkin.warn)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: UIScale.pt(10)) {
                    discoveryCommand
                    selectionCommand
                    lighthouseCommand
                    auditCommand
                }
                VStack(spacing: UIScale.pt(10)) {
                    discoveryCommand
                    selectionCommand
                    lighthouseCommand
                    auditCommand
                }
            }
        }
        .padding(UIScale.pt(14))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(14))
                .strokeBorder(DashSkin.accent(dark).opacity(0.28), lineWidth: UIScale.pt(1)))
    }

    private var discoveryCommand: some View {
        commandCell(
            icon: "point.3.connected.trianglepath.dotted", label: "DISCOVERED",
            value: String(model.discoveredPageURLs.count), detail: "pages from sitemap"
        ) {
            Button(action: model.discoverPages) {
                Label(
                    model.discoveredPageURLs.isEmpty ? "Discover pages" : "Discover more",
                    systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.isRunning)
        }
    }

    private var selectionCommand: some View {
        commandCell(
            icon: "checklist", label: "SELECTED", value: String(model.selectedPageCount),
            detail: "of \(model.discoveredPageURLs.count) pages"
        ) {
            Button("Choose pages") { pageSelectionPresented = true }
                .buttonStyle(.bordered)
                .disabled(model.discoveredPageURLs.isEmpty || model.isRunning)
        }
    }

    private var lighthouseCommand: some View {
        commandCell(
            icon: "gauge.with.needle", label: "LIGHTHOUSE",
            value: model.lighthouseEnabled ? "On" : "Off",
            detail: model.lighthouseEnabled ? "4 categories per page" : "metadata only"
        ) {
            Toggle("Include", isOn: $model.lighthouseEnabled)
                .toggleStyle(.checkbox)
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                .disabled(!model.lighthouseAvailable || model.isRunning)
        }
    }

    private var auditCommand: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Text("RUN")
                .font(DashSkin.mono(8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Text("Audit \(model.selectedPageCount) pages")
                .font(.system(size: UIScale.pt(12.5), weight: .semibold))
            Text(model.lighthouseEnabled ? "Metadata + Lighthouse" : "Metadata only")
                .font(.system(size: UIScale.pt(9.5)))
                .foregroundStyle(.secondary)
            Button(action: model.auditSelectedPages) {
                Label("Run selected", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedPageCount == 0 || model.isRunning)
        }
        .padding(UIScale.pt(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.accent(dark).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func commandCell<Actions: View>(
        icon: String, label: String, value: String, detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: icon).foregroundStyle(DashSkin.accent(dark))
                Text(label)
                    .font(DashSkin.mono(8, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
            Text(value).font(DashSkin.mono(19, weight: .semibold))
            Text(detail).font(.system(size: UIScale.pt(9.5))).foregroundStyle(.secondary)
            actions()
        }
        .padding(UIScale.pt(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

    private var runPicker: some View {
        HStack(spacing: UIScale.pt(8)) {
            Text("RUN HISTORY")
                .font(DashSkin.mono(8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Button {
                selectRun(at: selectedRunIndex + 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.edith(.toolbar))
            .help("Older run")
            .disabled(selectedRunIndex >= project.runs.count - 1)
            Menu {
                ForEach(Array(project.runs.enumerated()), id: \.element.id) { index, run in
                    Button {
                        model.selectRun(run.id)
                    } label: {
                        if run.id == model.selectedRun?.id {
                            Label(runMenuLabel(run, index: index), systemImage: "checkmark")
                        } else {
                            Text(runMenuLabel(run, index: index))
                        }
                    }
                }
            } label: {
                HStack(spacing: UIScale.pt(9)) {
                    Circle().fill(runStateColor(model.selectedRun?.state))
                        .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                    VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                        Text(
                            model.selectedRun?.startedAt.formatted(
                                .dateTime.month(.abbreviated).day().hour().minute()) ?? "No run"
                        )
                        .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                        Text(
                            model.selectedRun.map {
                                "\($0.pages.count) pages · \($0.state.rawValue)"
                            } ?? "Choose a saved run"
                        )
                        .font(DashSkin.mono(8.5))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: UIScale.pt(12))
                    Text("\(selectedRunIndex + 1) / \(project.runs.count)")
                        .font(DashSkin.mono(9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: UIScale.pt(8), weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, UIScale.pt(11))
                .frame(minWidth: UIScale.pt(250), minHeight: UIScale.pt(38))
                .background(
                    DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(9))
                        .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                selectRun(at: selectedRunIndex - 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.edith(.toolbar))
            .help("Newer run")
            .disabled(selectedRunIndex <= 0)
        }
    }

    private var selectedRunIndex: Int {
        project.runs.firstIndex { $0.id == model.selectedRun?.id } ?? 0
    }

    private func selectRun(at index: Int) {
        guard project.runs.indices.contains(index) else { return }
        model.selectRun(project.runs[index].id)
    }

    private func runMenuLabel(_ run: SEOAuditRun, index: Int) -> String {
        let date = run.startedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(index + 1). \(date), \(run.pages.count) pages"
    }

    private func runStateColor(_ state: SEOAuditRunState?) -> Color {
        switch state {
        case .completed: DashSkin.ok
        case .running: DashSkin.accent(dark)
        case .cancelled: DashSkin.warn
        case .failed: DashSkin.danger
        case nil: .secondary
        }
    }

    private var filters: some View {
        HStack(spacing: UIScale.pt(8)) {
            SearchField(placeholder: "Filter pages", text: $model.query)
                .frame(maxWidth: .infinity)
            Menu {
                Button("All issues") { model.severity = nil }
                Divider()
                ForEach(SEOAuditSeverity.allCases, id: \.self) { severity in
                    Button(severity.rawValue.capitalized) { model.severity = severity }
                }
            } label: {
                Label(
                    model.severity?.rawValue.capitalized ?? "All issues",
                    systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            Menu {
                ForEach(SEOAuditSocialPlatform.allCases) { platform in
                    Button {
                        model.socialPreviewPlatform = platform
                    } label: {
                        Label(platform.title, systemImage: platform.icon)
                    }
                }
            } label: {
                Label(
                    compact
                        ? model.socialPreviewPlatform.title
                        : "Preview: \(model.socialPreviewPlatform.title)",
                    systemImage: model.socialPreviewPlatform.icon)
            }
            .fixedSize()
            .help("Change every social card preview")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var pageList: some View {
        if model.selectedRun == nil, model.stage == .discovering {
            SEOAuditPageRowsSkeleton(dark: dark, rows: 3)
        } else if model.selectedRun == nil {
            emptyState(
                model.discoveredPageURLs.isEmpty ? "Discover the sitemap" : "Pages are ready",
                model.discoveredPageURLs.isEmpty
                    ? "Find pages first, then choose exactly what to audit."
                    : "Choose pages and run your first audit."
            )
        } else if model.visiblePages.isEmpty, model.isRunning {
            SEOAuditPageRowsSkeleton(dark: dark, rows: pendingSkeletonRows)
        } else if model.visiblePages.isEmpty {
            emptyState(
                "No pages match", "Clear the filters to see every page.")
        } else {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                PageSectionHeader(
                    "Pages",
                    subtitle:
                        "\(model.visiblePages.count) of \(model.selectedRun?.pages.count ?? 0) shown"
                )
                LazyVStack(spacing: UIScale.pt(8)) {
                    ForEach(model.visiblePages) { page in
                        SEOAuditPageAccordion(
                            page: page, history: model.history(for: page),
                            selected: Binding(
                                get: { model.selectedPageURLs.contains(page.url) },
                                set: { _ in model.togglePage(page.url) }),
                            lighthouseAvailable: model.lighthouseAvailable,
                            lighthouseRunning: model.activeLighthouseURL == page.url,
                            runLighthouse: { model.runLighthouse(for: page) },
                            socialPlatform: model.socialPreviewPlatform,
                            expanded: Binding(
                                get: { expandedPages.contains(page.id) },
                                set: { open in
                                    if open {
                                        expandedPages.insert(page.id)
                                    } else {
                                        expandedPages.remove(page.id)
                                    }
                                }))
                    }
                    if model.isRunning {
                        SEOAuditPageRowsSkeleton(dark: dark, rows: pendingSkeletonRows)
                    }
                }
            }
        }
    }

    private var pendingSkeletonRows: Int {
        switch model.stage {
        case let .auditing(current, total, _): min(3, max(1, total - current + 1))
        case .discovering, .lighthouse, .saving: 1
        case .idle: 1
        }
    }

    private func emptyState(_ title: String, _ detail: String) -> some View {
        VStack(spacing: UIScale.pt(8)) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: UIScale.pt(26), weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: UIScale.pt(14), weight: .semibold))
            Text(detail).font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UIScale.pt(44))
    }
}

private struct SEOAuditProgressRail: View {
    let stage: SEOAuditStage
    let progress: Double
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(8)) {
                SkeletonGroup {
                    SkeletonBlock(width: 12, height: 12, corner: 6)
                }
                .accessibilityLabel(title)
                Text(title).font(.system(size: UIScale.pt(12), weight: .semibold))
                Text(detail)
                    .font(DashSkin.mono(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(DashSkin.mono(11, weight: .semibold))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(DashSkin.line(dark))
                    Capsule().fill(DashSkin.accent(dark))
                        .frame(width: max(UIScale.pt(6), geometry.size.width * progress))
                    Circle().fill(DashSkin.paper2(dark))
                        .overlay(
                            Circle().strokeBorder(DashSkin.accent(dark), lineWidth: UIScale.pt(2))
                        )
                        .frame(width: UIScale.pt(9), height: UIScale.pt(9))
                        .offset(x: max(0, geometry.size.width * progress - UIScale.pt(5)))
                }
            }
            .frame(height: UIScale.pt(9))
        }
        .padding(UIScale.pt(12))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(11)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(11))
                .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1)))
    }

    private var title: String {
        switch stage {
        case .idle: "Ready"
        case .discovering: "Discovering pages"
        case .auditing: "Auditing pages"
        case .lighthouse: "Running Lighthouse"
        case .saving: "Saving run"
        }
    }

    private var detail: String {
        switch stage {
        case .idle: ""
        case .discovering: "robots.txt → sitemap.xml"
        case let .auditing(current, total, url): "\(current) / \(total)  \(url)"
        case let .lighthouse(url): url
        case .saving: "writing local history"
        }
    }
}

private struct SEOAuditPageSelectionSheet: View {
    @Bindable var model: SEOAuditModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(12)) {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("Choose pages").font(DashSkin.serif(22))
                    Text("\(model.selectedPageCount) of \(model.discoveredPageURLs.count) selected")
                        .font(DashSkin.mono(9.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select all", action: model.selectAllPages)
                Button("Clear", action: model.deselectAllPages)
                Button("Done", action: dismiss.callAsFunction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(UIScale.pt(18))
            Divider()
            SearchField(placeholder: "Filter discovered URLs", text: $model.pageSelectionQuery)
                .padding(UIScale.pt(14))
            ScrollView {
                LazyVStack(spacing: UIScale.pt(6)) {
                    ForEach(model.visibleDiscoveredPageURLs, id: \.self) { url in
                        Button {
                            model.togglePage(url)
                        } label: {
                            HStack(spacing: UIScale.pt(10)) {
                                Image(
                                    systemName: model.selectedPageURLs.contains(url)
                                        ? "checkmark.square.fill" : "square"
                                )
                                .foregroundStyle(
                                    model.selectedPageURLs.contains(url)
                                        ? DashSkin.accent(dark) : .secondary)
                                Text(url)
                                    .font(DashSkin.mono(10.5))
                                    .foregroundStyle(DashSkin.ink(dark))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, UIScale.pt(12))
                            .frame(minHeight: UIScale.pt(36))
                            .background(
                                model.selectedPageURLs.contains(url)
                                    ? DashSkin.accent(dark).opacity(0.08) : DashSkin.paper2(dark),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                        }
                        .buttonStyle(.edith(.borderless))
                    }
                }
                .padding(.horizontal, UIScale.pt(14))
                .padding(.bottom, UIScale.pt(14))
            }
        }
        .frame(minWidth: UIScale.pt(620), minHeight: UIScale.pt(520))
        .background(DashSkin.paper(dark))
        .onDisappear { model.pageSelectionQuery = "" }
    }
}
