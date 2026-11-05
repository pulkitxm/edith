import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct SEOAuditProjectView: View {
    private static let inactiveProject = SEOAuditProject(name: "Site Audit", baseURL: "")

    @Bindable var model: SEOAuditModel
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @State private var expandedPages = Set<UUID>()
    @State private var confirmsDeletion = false
    @State private var pageSelectionPresented = false

    private var dark: Bool { scheme == .dark }
    private var project: SEOAuditProject {
        model.selectedProject ?? Self.inactiveProject
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                LazyVStack(
                    alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing),
                    pinnedViews: [.sectionHeaders]
                ) {
                    if !project.runs.isEmpty { summary }
                    if !project.runs.isEmpty || !model.discoveredPageURLs.isEmpty {
                        commandDeck
                    }
                    Section {
                        pageList
                    } header: {
                        if !project.runs.isEmpty { pinnedControls }
                    }
                }
                .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
                .pageContent(compact)
            }
        }
        .confirmationDialog(
            SEOAuditPrivacyState.shared.hidden
                ? "Delete this project?" : "Delete \(project.name)?",
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                Task { await model.deleteSelectedProject() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Every saved run and page result for this project will be removed from this Mac. The website itself is not affected."
            )
        }
        .edithSheet(isPresented: $pageSelectionPresented) {
            SEOAuditPageSelectionSheet(model: model)
        }
        .onChange(of: model.selectedRunID) { _, _ in expandedPages.removeAll() }
    }

    private var toolbar: some View {
        PageHeader(
            project.name, subtitle: project.baseURL, divider: true,
            trailing: {
                HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                    Button("Projects", systemImage: "chevron.left", action: model.closeProject)
                        .help(
                            model.isRunning
                                ? "View projects while this audit continues" : "Back to projects")
                    if model.isRunning {
                        Button("Stop", role: .destructive, action: model.cancel)
                    } else {
                        Button("New project", systemImage: "plus", action: model.leaveForNewProject)
                    }
                    Menu {
                        Button("Delete Project", role: .destructive) { confirmsDeletion = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Project actions")
                    .disabled(model.isRunning)
                }
            },
            accessory: {
                if model.isRunning {
                    SEOAuditProgressRail(
                        stage: model.stage, progress: model.selectedRun?.progress ?? 0)
                }
            })
    }

    private var summary: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(
                    .flexible(), spacing: UIScale.pt(PageMetrics.cardSpacing), alignment: .top),
                count: compact ? 2 : 4),
            spacing: UIScale.pt(PageMetrics.cardSpacing)
        ) {
            metric(
                "Pages", model.selectedRun.map { String($0.pages.count) } ?? "0", "in this run",
                "doc.on.doc")
            metric(
                "Issues", model.selectedRun.map { String($0.issueCount) } ?? "0",
                "across all pages", "exclamationmark.triangle")
            metric(
                "Average", model.selectedRun?.averageScore.map(String.init) ?? "-",
                "Lighthouse score", "gauge.with.needle")
            metric(
                "Runs", String(project.runs.count), "saved on this Mac",
                "clock.arrow.trianglehead.counterclockwise.rotate.90")
        }
    }

    private func metric(_ title: String, _ value: String, _ detail: String, _ icon: String)
        -> some View
    {
        PageMetric(
            title: title, value: value, detail: detail, symbol: icon,
            tint: DashSkin.accent(dark))
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
            .padding(.vertical, UIScale.pt(8))
            .background(DashSkin.paper(dark))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DashSkin.line(dark))
                    .frame(height: 1)
            }
            .zIndex(1)
    }

    private var commandDeck: some View {
        PageCard(title: "Audit", note: "Find pages, choose which to check, then run") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                    discoveryCommand
                    selectionCommand
                    lighthouseCommand
                    auditCommand
                }
                .fixedSize(horizontal: false, vertical: true)
                Grid(
                    horizontalSpacing: UIScale.pt(PageMetrics.cardSpacing),
                    verticalSpacing: UIScale.pt(PageMetrics.cardSpacing)
                ) {
                    GridRow {
                        discoveryCommand
                        selectionCommand
                    }
                    GridRow {
                        lighthouseCommand
                        auditCommand
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if model.lighthouseResolved, !model.lighthouseAvailable {
                Label(
                    "Lighthouse is not installed, so scores are skipped. Audits still check titles, descriptions and links.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .help("Install it with npm install -g lighthouse.")
                .font(.edithText(.callout))
                .foregroundStyle(DashSkin.warn)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var discoveryCommand: some View {
        commandCell(
            icon: "point.3.connected.trianglepath.dotted", label: "Found",
            value: String(model.discoveredPageURLs.count), detail: "pages found in your sitemap"
        ) {
            Button(action: model.discoverPages) {
                Label(
                    model.discoveredPageURLs.isEmpty ? "Find pages" : "Find again",
                    systemImage: "arrow.clockwise")
            }
            .buttonStyle(.edith(.secondary))
            .disabled(model.isRunning)
            .help(
                model.isRunning
                    ? "Available when the audit finishes." : "Read the sitemap to list your pages")
        }
    }

    private var selectionCommand: some View {
        commandCell(
            icon: "checklist", label: "Selected", value: String(model.selectedPageCount),
            detail: "of \(model.discoveredPageURLs.count) pages"
        ) {
            Button("Choose pages") { pageSelectionPresented = true }
                .buttonStyle(.edith(.secondary))
                .disabled(model.discoveredPageURLs.isEmpty || model.isRunning)
                .help(
                    model.discoveredPageURLs.isEmpty
                        ? "Find pages first." : "Pick which pages to audit")
        }
    }

    private var lighthouseCommand: some View {
        commandCell(
            icon: "gauge.with.needle", label: "Lighthouse",
            value: model.lighthouseEnabled ? "On" : "Off",
            detail: model.lighthouseEnabled
                ? "scores for speed, accessibility, SEO" : "titles, descriptions and links only"
        ) {
            Toggle("Include", isOn: $model.lighthouseEnabled)
                .toggleStyle(.checkbox)
                .font(.edithText(.caption).weight(.medium))
                .disabled(!model.lighthouseAvailable || model.isRunning)
                .help(
                    model.lighthouseAvailable
                        ? "Adds a Lighthouse score to each page. Slower."
                        : "Install the Lighthouse CLI to enable page scores.")
        }
    }

    private var auditCommand: some View {
        commandCell(
            icon: "play.circle", label: "Run", value: "\(model.selectedPageCount)",
            detail: model.lighthouseEnabled
                ? "pages, with Lighthouse scores" : "pages, metadata only",
            highlighted: true
        ) {
            Button(action: model.auditSelectedPages) {
                Label("Run audit", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.edith(.primary))
            .disabled(model.selectedPageCount == 0 || model.isRunning)
            .help(
                model.isRunning
                    ? "An audit is already running."
                    : model.selectedPageCount == 0
                        ? "Find and choose at least one page first." : "Start the audit")
        }
    }

    private func commandCell<Actions: View>(
        icon: String, label: String, value: String, detail: String, highlighted: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: icon)
                    .font(.edithText(.caption))
                    .foregroundStyle(DashSkin.accent(dark))
                    .accessibilityHidden(true)
                PageCapsLabel(label)
            }
            Text(value).font(.edithText(.title2).weight(.semibold)).monospacedDigit()
            Text(detail).font(.edithText(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: UIScale.pt(8))
            actions()
        }
        .padding(UIScale.pt(12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            highlighted ? DashSkin.accent(dark).opacity(0.08) : DashSkin.paper(dark),
            in: RoundedRectangle(cornerRadius: UIScale.pt(PageMetrics.chipCornerRadius + 2)))
    }

    private var runPicker: some View {
        HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            PageCapsLabel("Run history")
            runStepButton("chevron.left", label: "Older run") {
                selectRun(at: selectedRunIndex + 1)
            }
            .disabled(selectedRunIndex >= project.runs.count - 1)
            PageMenuChip(selectedRunTitle, dot: runStateColor(model.selectedRun?.state)) {
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
            }
            runStepButton("chevron.right", label: "Newer run") {
                selectRun(at: selectedRunIndex - 1)
            }
            .disabled(selectedRunIndex <= 0)
        }
    }

    private func runStepButton(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(10), weight: .semibold))
                .frame(width: UIScale.pt(10))
        }
        .buttonStyle(.pageChip())
        .help(label)
        .accessibilityLabel(label)
    }

    private var selectedRunTitle: String {
        guard let run = model.selectedRun else { return "No run" }
        let date = run.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "\(date) · \(run.pages.count) pages"
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
        HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            SearchField(placeholder: "Filter pages", text: $model.query, compact: true)
                .frame(maxWidth: .infinity)
            PageMenuChip(
                model.severity?.rawValue.capitalized ?? "All issues",
                systemImage: "line.3.horizontal.decrease", active: model.severity != nil
            ) {
                Button("All issues") { model.severity = nil }
                Divider()
                ForEach(SEOAuditSeverity.allCases, id: \.self) { severity in
                    Button(severity.rawValue.capitalized) { model.severity = severity }
                }
            }
            PageMenuChip(
                compact
                    ? model.socialPreviewPlatform.title
                    : "Preview: \(model.socialPreviewPlatform.title)",
                systemImage: model.socialPreviewPlatform.icon
            ) {
                ForEach(SEOAuditSocialPlatform.allCases) { platform in
                    Button {
                        model.socialPreviewPlatform = platform
                    } label: {
                        Label(platform.title, systemImage: platform.icon)
                    }
                }
            }
            .help("Change every social card preview")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var pageList: some View {
        if model.selectedRun == nil, model.stage == .discovering {
            SEOAuditPageRowsSkeleton(dark: dark, rows: 3)
        } else if model.selectedRun == nil {
            if model.discoveredPageURLs.isEmpty {
                PageEmptyState(
                    symbolName: "point.3.connected.trianglepath.dotted",
                    title: "Find the pages to audit",
                    message:
                        "Edith reads the sitemap of \(project.baseURL.isEmpty ? "your site" : project.baseURL) to list its pages. Then you choose which ones to check. Nothing is changed on your site.",
                    primary: PageAction(
                        "Find pages", symbolName: "magnifyingglass", identifier: "seo.discover",
                        perform: model.discoverPages)
                )
                .frame(minHeight: UIScale.pt(300))
            } else {
                PageEmptyState(
                    symbolName: "play.circle",
                    title: "\(model.discoveredPageURLs.count) pages ready to audit",
                    message:
                        "\(model.selectedPageCount) are selected. Run the audit above to check each page's titles, descriptions, headings and share cards.",
                    style: .compact
                )
                .frame(minHeight: UIScale.pt(200))
            }
        } else if model.visiblePages.isEmpty, model.isRunning {
            SEOAuditPageRowsSkeleton(dark: dark, rows: pendingSkeletonRows)
        } else if model.visiblePages.isEmpty {
            PageEmptyState(
                symbolName: "line.3.horizontal.decrease.circle", title: "No pages match",
                message: "Nothing in this run fits the current filter.",
                primary: PageAction("Clear filters") {
                    model.query = ""
                    model.severity = nil
                }
            )
            .frame(minHeight: UIScale.pt(240))
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
                            page: page, history: model.historyByURL[page.url] ?? [],
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
                Text(title).font(.edithText(.callout).weight(.semibold))
                Text(detail)
                    .font(.edithText(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.edithText(.callout).weight(.semibold))
                    .monospacedDigit()
            }
            LoadingProgress(value: progress)
                .tint(DashSkin.accent(dark))
        }
    }

    private var title: String {
        switch stage {
        case .idle: "Ready"
        case .discovering: "Finding pages"
        case .auditing: "Auditing pages"
        case .lighthouse: "Running Lighthouse"
        case .saving: "Saving run"
        }
    }

    private var detail: String {
        switch stage {
        case .idle: ""
        case .discovering: "Reading your sitemap"
        case let .auditing(current, total, url): "\(current) of \(total), \(url)"
        case let .lighthouse(url): url
        case .saving: "Saving to this Mac"
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
                    Text("Choose pages").font(.edithText(.title2)).fontWeight(.semibold)
                    Text("\(model.selectedPageCount) of \(model.discoveredPageURLs.count) selected")
                        .font(.edithText(.callout))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select all", action: model.selectAllPages)
                Button("Clear", action: model.deselectAllPages)
                Button("Done", action: dismiss.callAsFunction)
                    .buttonStyle(.edith(.primary))
            }
            .padding(UIScale.pt(16))
            Divider()
            SearchField(placeholder: "Filter discovered URLs", text: $model.pageSelectionQuery)
                .padding(UIScale.pt(16))
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
                                    .font(.edithText(.callout))
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
                .padding(.horizontal, UIScale.pt(16))
                .padding(.bottom, UIScale.pt(16))
            }
        }
        .frame(width: PresentationMetrics.width(620), height: PresentationMetrics.height(520))
        .background(DashSkin.paper(dark))
        .presenterCover(SEOAuditPrivacyState.shared.hidden)
        .onDisappear { model.pageSelectionQuery = "" }
    }
}
