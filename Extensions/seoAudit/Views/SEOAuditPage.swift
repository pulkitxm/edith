import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct SEOAuditPage: View {
    @State private var model: SEOAuditModel

    init(model: SEOAuditModel? = nil) { _model = State(initialValue: model ?? .shared) }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    private var projectBinding: Binding<String> {
        Binding(
            get: {
                guard model.projectDetailPresented, let id = model.selectedProject?.id else {
                    return ""
                }
                return id.uuidString
            },
            set: { raw in
                if raw.isEmpty {
                    model.closeProject()
                    return
                }
                guard let id = UUID(uuidString: raw) else { return }
                Task { await model.selectProject(id: id) }
            })
    }

    private func projectIsValid(_ raw: String) -> Bool {
        guard let id = UUID(uuidString: raw) else { return false }
        return model.projects.contains { $0.id == id } || model.selectedProject?.id == id
    }

    var body: some View {
        Group {
            if model.projectDetailPresented, model.selectedProject != nil {
                SEOAuditProjectView(model: model)
            } else {
                SEOAuditProjectsView(model: model)
            }
        }
        .presenterCover(SEOAuditPrivacyState.shared.hidden)
        .background(DashSkin.paper(scheme == .dark))
        .navigationRoute(
            "project", selection: projectBinding, isValid: projectIsValid,
            isReady: model.projectsLoaded
        )
        .pageTask {
            await model.refreshProjects()
        }
        .edithSheet(isPresented: $model.newProjectPresented, dismissible: false) {
            SEOAuditNewProjectSheet(model: model)
        }
        .alert(
            "Site Audit could not finish",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(
                SEOAuditPrivacyState.shared.hidden
                    ? "The audit ran into a problem."
                    : (model.errorMessage ?? ""))
        }
    }
}

private struct SEOAuditProjectsView: View {
    @Bindable var model: SEOAuditModel
    @State private var projectBeingRenamed: SEOAuditProjectSummary?
    @State private var projectBeingDeleted: SEOAuditProjectSummary?

    var body: some View {
        PageScaffold(pinnedHeader: true) {
            PageHeader(
                "Site Audit",
                subtitle: "Check a website for SEO problems. Results stay on this Mac.",
                divider: true,
                trailing: {
                    if !(model.projectsLoaded && model.projects.isEmpty) {
                        Button(action: model.presentNewProject) {
                            Label("New project", edith: .plus)
                        }
                        .buttonStyle(.edith(.primary))
                        .disabled(model.isRunning)
                        .help(
                            model.isRunning
                                ? "Wait for the running audit to finish or stop it first."
                                : "Add a website to audit")
                    }
                })
        } content: {
            if model.projectsLoaded, let error = model.projectsLoadError {
                PageNotice(
                    error, tone: .error,
                    actions: {
                        Button("Retry") { Task { await model.refreshProjects() } }
                    })
            }
            projects
        }
        .edithSheet(item: $projectBeingRenamed, dismissible: false) { project in
            SEOAuditRenameProjectSheet(project: project) { name in
                Task { await model.renameProject(id: project.id, to: name) }
            }
        }
        .alert(
            SEOAuditPrivacyState.shared.hidden
                ? "Delete this project?"
                : "Delete \(projectBeingDeleted?.name ?? "project")?",
            isPresented: Binding(
                get: { projectBeingDeleted != nil },
                set: { if !$0 { projectBeingDeleted = nil } })
        ) {
            Button("Cancel", role: .cancel) { projectBeingDeleted = nil }
            Button("Delete", role: .destructive) {
                guard let project = projectBeingDeleted else { return }
                Task { await model.deleteProject(id: project.id) }
                projectBeingDeleted = nil
            }
        } message: {
            Text(
                "This removes the project and every saved audit run for it from this Mac. The website itself is not affected."
            )
        }
    }

    private var projects: some View {
        PageLoading(
            state: model.projectsLoad.state,
            message: model.projectsLoadError ?? "",
            layout: .list, showsSkeletonControls: false,
            refreshing: model.projectsLoad.isRefreshing,
            retry: { Task { await model.refreshProjects() } }
        ) {
            projectContent
        }
    }

    @ViewBuilder
    private var projectContent: some View {
        if model.projects.isEmpty {
            PageEmptyState(
                icon: .seoAudit,
                title: "Check your website for SEO problems",
                message:
                    "Enter your site's address and Edith finds its pages, then checks titles, descriptions, share cards and more, one page at a time.",
                steps: [
                    PageGuideStep(
                        icon: .link, title: "Add your site",
                        detail: "Type a URL such as example.com or localhost:3000."),
                    PageGuideStep(
                        icon: .nodes,
                        title: "Find its pages",
                        detail: "Edith reads your sitemap, then you choose which pages to check."),
                    PageGuideStep(
                        icon: .clipboard, title: "Read the report",
                        detail: "See issues per page, how it looks when shared, and past runs."),
                ],
                primary: PageAction(
                    "Add your site", icon: .plus, identifier: "seo.new-project",
                    perform: model.presentNewProject),
                footnote:
                    "Audits only read your public pages. Results are saved on this Mac and never uploaded."
            )
            .pageFillViewport()
        } else {
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                PageSectionHeader(
                    "Projects",
                    subtitle: model.projects.count == 1
                        ? "1 website" : "\(model.projects.count) websites")
                VStack(spacing: 0) {
                    ForEach(Array(model.projects.enumerated()), id: \.element.id) {
                        index, project in
                        if index > 0 {
                            Divider().padding(.leading, UIScale.pt(SEOAuditProjectRow.dividerInset))
                        }
                        let active = model.isRunning && model.selectedProject?.id == project.id
                        SEOAuditProjectRow(
                            project: project,
                            activeStage: active ? model.stage : nil,
                            activeRun: active ? model.selectedRun : nil,
                            canViewDetails: !model.isRunning
                                || model.selectedProject?.id == project.id,
                            actionsEnabled: !model.isRunning,
                            viewDetails: { Task { await model.selectProject(id: project.id) } },
                            rename: { projectBeingRenamed = project },
                            delete: { projectBeingDeleted = project })
                    }
                }
                .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: UIScale.pt(PageMetrics.cardCornerRadius),
                        style: .continuous))
            }
        }
    }
}

struct SEOAuditNewProjectSheet: View {
    @Bindable var model: SEOAuditModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.top)) {
            HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                EdithIconView(.nodes)
                    .font(.system(size: UIScale.pt(21), weight: .medium))
                    .foregroundStyle(DashSkin.accent(dark))
                    .frame(width: UIScale.pt(38), height: UIScale.pt(38))
                    .background(DashSkin.accent(dark).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.subtitleSpacing)) {
                    Text("New audit project")
                        .font(.edithText(.title3)).fontWeight(.semibold)
                    Text(
                        "Add the site once. Every audit of it is saved under this project so you can compare runs."
                    )
                    .font(.edithText(.subheadline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                fieldLabel("Site URL")
                EdithTextField(
                    placeholder: "localhost:3000 or example.com", text: $model.input,
                    icon: .link, clearable: true,
                    onSubmit: { Task { await model.beginNewProject() } })
                fieldLabel("Project name").padding(.top, UIScale.pt(4))
                EdithTextField(
                    placeholder: "Optional, defaults to the site address", text: $model.projectName,
                    icon: .folder)
            }
            if model.lighthouseResolved {
                lighthouseNote
            }
            HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                Button("Cancel") {
                    model.newProjectPresented = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter a site address first")
                        .font(.edithText(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button(action: { Task { await model.beginNewProject() } }) {
                    Label("Create and find pages", edith: .arrowRight)
                }
                .buttonStyle(.edith(.primary))
                .keyboardShortcut(.defaultAction)
                .fixedSize()
                .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(UIScale.pt(PageMetrics.gutter))
        .buttonStyle(.edith(.secondary))
        .frame(width: PresentationMetrics.width(500))
        .background(DashSkin.paper(dark))
        .presenterCover(SEOAuditPrivacyState.shared.hidden)
    }

    private func fieldLabel(_ value: String) -> some View {
        PageCapsLabel(value)
    }

    private var lighthouseNote: some View {
        let available = model.lighthouseAvailable
        return Label {
            Text(
                available
                    ? "Lighthouse is installed, so audits can also score speed and accessibility."
                    : "Lighthouse is not installed. Audits still check titles, descriptions and links."
            )
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            EdithIconView(available ? .success : .info)
                .foregroundStyle(available ? DashSkin.ok : Color.secondary)
                .accessibilityHidden(true)
        }
        .font(.edithText(.subheadline))
        .foregroundStyle(.secondary)
    }
}

private struct SEOAuditProjectRow: View {
    static let thumbnailWidth = 72.0
    static let thumbnailHeight = 44.0
    static let horizontalPadding = 14.0
    static let spacing = 12.0
    static let metricWidth = 52.0
    static let statusWidth = 150.0
    static let updatedWidth = 112.0
    static let menuSize = 28.0
    static var dividerInset: Double { horizontalPadding + thumbnailWidth + spacing }

    let project: SEOAuditProjectSummary
    let activeStage: SEOAuditStage?
    let activeRun: SEOAuditRun?
    let canViewDetails: Bool
    let actionsEnabled: Bool
    let viewDetails: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @State private var hovered = false
    @State private var snapshotImage: NSImage?
    @State private var imageFinished = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: viewDetails) {
                HStack(spacing: UIScale.pt(Self.spacing)) {
                    thumbnail
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(project.name)
                            .font(.edithText(.body).weight(.semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                        Text(project.baseURL)
                            .font(.edithText(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if compact {
                            HStack(spacing: UIScale.pt(Self.spacing)) {
                                status
                                updated
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !compact {
                        status.frame(width: UIScale.pt(Self.statusWidth), alignment: .leading)
                    }
                    metric("Pages", displayedPageCount)
                    metric("Issues", displayedIssueCount)
                    metric("Score", displayedAverageScore)
                    if !compact {
                        updated.frame(width: UIScale.pt(Self.updatedWidth), alignment: .trailing)
                    }
                    Color.clear
                        .frame(width: UIScale.pt(Self.menuSize), height: UIScale.pt(Self.menuSize))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, UIScale.pt(Self.horizontalPadding))
                .padding(.vertical, UIScale.pt(10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered && canViewDetails ? Color.primary.opacity(0.04) : .clear)
                .overlay(alignment: .bottom) { progressBar }
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .disabled(!canViewDetails)
            .accessibilityLabel("View details for \(project.name)")

            Menu {
                projectActions
            } label: {
                EdithIcon.more.image()
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .frame(width: UIScale.pt(Self.menuSize), height: UIScale.pt(Self.menuSize))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, UIScale.pt(Self.horizontalPadding))
            .accessibilityLabel("Project actions for \(project.name)")
        }
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.16), value: hovered)
        .contextMenu { projectActions }
    }

    @ViewBuilder
    private var projectActions: some View {
        Button(action: viewDetails) {
            Label("View details", edith: .seoAudit)
        }
        .disabled(!canViewDetails)
        Button(action: rename) {
            Label("Rename", edith: .edit)
        }
        .disabled(!actionsEnabled)
        Divider()
        Button(role: .destructive, action: delete) {
            Label("Delete", edith: .trash)
        }
        .disabled(!actionsEnabled)
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(
                LinearGradient(
                    colors: [DashSkin.accent(dark).opacity(0.28), DashSkin.paper(dark)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            if let snapshotImage {
                Image(nsImage: snapshotImage).resizable().scaledToFill()
            } else if !imageFinished, snapshotFileURL != nil || project.imageURL != nil {
                SEOAuditImageSkeleton()
            } else {
                projectMark
            }
        }
        .frame(width: UIScale.pt(Self.thumbnailWidth), height: UIScale.pt(Self.thumbnailHeight))
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
                .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1))
        )
        .pageTask(id: snapshotFileURL?.absoluteString ?? project.imageURL) {
            snapshotImage = nil; imageFinished = false
            guard !SEOAuditPrivacyState.shared.hidden,
                let url = snapshotFileURL
                    ?? (automaticActionsEnabled ? project.imageURL.flatMap(URL.init(string:)) : nil)
            else { imageFinished = true; return }
            let loaded = await SEOSnapshotCache.image(for: url)
            guard !Task.isCancelled, !SEOAuditPrivacyState.shared.hidden else { return }
            snapshotImage = loaded; imageFinished = true
        }
    }

    private var status: some View {
        HStack(spacing: UIScale.pt(7)) {
            if activeStage != nil {
                SkeletonGroup {
                    SkeletonBlock(width: 9, height: 9, corner: 4.5)
                }
                .accessibilityLabel("Audit in progress")
            }
            Text(activityLabel)
            if let activeProgress {
                Text(activeProgress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
        }
        .font(.edithText(.caption).weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var updated: some View {
        Text(project.updatedAt, format: .relative(presentation: .named))
            .font(.edithText(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder private var progressBar: some View {
        if let activeProgress {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(DashSkin.line(dark))
                    Rectangle().fill(DashSkin.accent(dark))
                        .frame(width: geometry.size.width * activeProgress)
                }
            }
            .frame(height: UIScale.pt(3))
        }
    }

    private var snapshotFileURL: URL? {
        guard let value = project.imageSnapshotURL, let url = URL(string: value), url.isFileURL
        else { return nil }
        return url
    }

    private var activityLabel: String {
        guard let activeStage else {
            return project.latestRun?.state.rawValue.capitalized ?? "Not audited yet"
        }
        switch activeStage {
        case .idle: return project.latestRun?.state.rawValue.capitalized ?? "Not audited yet"
        case .discovering: return "Finding pages"
        case let .auditing(current, total, _): return "Auditing \(current) of \(total)"
        case .lighthouse: return "Running Lighthouse"
        case .saving: return "Saving results"
        }
    }

    private var activeProgress: Double? {
        guard let activeStage else { return nil }
        switch activeStage {
        case .discovering, .lighthouse, .idle: return nil
        case .auditing: return activeRun?.progress ?? 0
        case .saving: return 1
        }
    }

    private var displayedPageCount: String {
        activeRun.map { String($0.pages.count) }
            ?? project.latestRun.map { String($0.pageCount) } ?? "-"
    }

    private var displayedIssueCount: String {
        activeRun.map { String($0.issueCount) }
            ?? project.latestRun.map { String($0.issueCount) } ?? "-"
    }

    private var displayedAverageScore: String {
        activeRun?.averageScore.map(String.init)
            ?? project.latestRun?.averageScore.map(String.init) ?? "-"
    }

    private var projectMark: some View {
        EdithIconView(.globe)
            .font(.system(size: UIScale.pt(20), weight: .light))
            .foregroundStyle(DashSkin.accent(dark))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: UIScale.pt(1)) {
            Text(value).font(.edithText(.body).weight(.semibold)).monospacedDigit()
            Text(label).font(.edithText(.caption)).foregroundStyle(.secondary)
        }
        .frame(width: UIScale.pt(Self.metricWidth), alignment: .trailing)
    }
}

private struct SEOAuditRenameProjectSheet: View {
    let project: SEOAuditProjectSummary
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(project: SEOAuditProjectSummary, save: @escaping (String) -> Void) {
        self.project = project
        self.save = save
        _name = State(initialValue: project.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text("Rename project")
                    .font(.edithText(.title3)).fontWeight(.semibold)
                Text(project.baseURL)
                    .font(.edithText(.subheadline))
                    .foregroundStyle(.secondary)
            }
            EdithTextField(
                placeholder: "Project name", text: $name, icon: .folder, clearable: true,
                onSubmit: submit)
            HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save name", action: submit)
                    .buttonStyle(.edith(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(UIScale.pt(PageMetrics.gutter))
        .buttonStyle(.edith(.secondary))
        .frame(width: PresentationMetrics.width(420))
        .presenterCover(SEOAuditPrivacyState.shared.hidden)
    }

    private func submit() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        save(value)
        dismiss()
    }
}
