import EdithKit
import SwiftUI

struct SEOAuditPage: View {
    @State private var model: SEOAuditModel
    @Environment(\.colorScheme) private var scheme

    @MainActor
    init() {
        _model = State(initialValue: SEOAuditModel())
    }

    var body: some View {
        Group {
            if model.selectedProject == nil {
                SEOAuditProjectsView(model: model)
            } else {
                SEOAuditProjectView(model: model)
            }
        }
        .background(DashSkin.paper(scheme == .dark))
        .sheet(isPresented: $model.newProjectPresented) {
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
            Text(model.errorMessage ?? "")
        }
    }
}

private struct SEOAuditProjectsView: View {
    @Bindable var model: SEOAuditModel
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: UIScale.pt(20)) {
                PageHeader {
                    Text("Site Audit")
                } accessory: {
                    HStack(spacing: UIScale.pt(14)) {
                        Text("Crawl every page, inspect every share card, and keep each run local.")
                            .font(.system(size: UIScale.pt(13)))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                        Button(action: model.presentNewProject) {
                            Label("New project", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                projects
                    .pageGutter(compact)
            }
            .padding(.bottom, UIScale.pt(PageMetrics.bottom))
        }
    }

    @ViewBuilder
    private var projects: some View {
        if model.projects.isEmpty {
            VStack(spacing: UIScale.pt(10)) {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.system(size: UIScale.pt(28), weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No projects yet")
                    .font(DashSkin.serif(20))
                Text("Your first completed crawl will stay here with its full history.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
                Button(action: model.presentNewProject) {
                    Label("Create a project", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UIScale.pt(52))
        } else {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                PageSectionHeader(
                    "Projects", subtitle: "\(model.projects.count) local workspaces")
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: UIScale.pt(compact ? 240 : 290)),
                            spacing: UIScale.pt(14))
                    ], spacing: UIScale.pt(14)
                ) {
                    ForEach(model.projects) { project in
                        SEOAuditProjectCard(project: project) {
                            model.selectProject(id: project.id)
                        }
                    }
                }
            }
        }
    }
}

private struct SEOAuditNewProjectSheet: View {
    @Bindable var model: SEOAuditModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(20)) {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: UIScale.pt(21), weight: .medium))
                    .foregroundStyle(DashSkin.accent(dark))
                    .frame(width: UIScale.pt(38), height: UIScale.pt(38))
                    .background(DashSkin.accent(dark).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text("New audit project")
                        .font(DashSkin.serif(23))
                    Text("Add the site once. Every audit run stays attached to this project.")
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                fieldLabel("Site URL")
                EdithTextField(
                    placeholder: "localhost:3000 or example.com", text: $model.input,
                    icon: "link", clearable: true, onSubmit: model.beginNewProject)
                fieldLabel("Project name")
                EdithTextField(
                    placeholder: "Optional", text: $model.projectName, icon: "folder")
            }
            HStack(spacing: UIScale.pt(10)) {
                capability("Sitemap discovery", "point.3.connected.trianglepath.dotted", true)
                capability(
                    model.lighthouseAvailable
                        ? "Lighthouse detected" : "Lighthouse not installed",
                    "gauge.with.needle", model.lighthouseAvailable)
            }
            HStack {
                Button("Cancel") {
                    model.newProjectPresented = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter a site URL to continue")
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(.secondary)
                }
                Button(action: model.beginNewProject) {
                    Label("Create and discover", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(UIScale.pt(24))
        .frame(width: UIScale.pt(500))
        .background(DashSkin.paper(dark))
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value.uppercased())
            .font(DashSkin.mono(8.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }

    private func capability(_ title: String, _ icon: String, _ available: Bool) -> some View {
        HStack(spacing: UIScale.pt(7)) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(available ? DashSkin.ok : DashSkin.warn)
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).font(.system(size: UIScale.pt(10.5), weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(10))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
    }
}

private struct SEOAuditProjectCard: View {
    let project: SEOAuditProjectSummary
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                artwork
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(project.name)
                            .font(.system(size: UIScale.pt(15), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                        Spacer(minLength: UIScale.pt(8))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: UIScale.pt(10), weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(project.baseURL)
                        .font(DashSkin.mono(10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Divider()
                    HStack(spacing: UIScale.pt(16)) {
                        cardMetric("Pages", project.latestRun.map { String($0.pageCount) } ?? "—")
                        cardMetric("Issues", project.latestRun.map { String($0.issueCount) } ?? "—")
                        cardMetric("Score", project.latestRun?.averageScore.map(String.init) ?? "—")
                        Spacer(minLength: 0)
                        Text(project.updatedAt, format: .relative(presentation: .named))
                            .font(.system(size: UIScale.pt(10)))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(UIScale.pt(14))
            }
            .background(DashSkin.paper2(dark))
            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(15)))
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(15))
                    .strokeBorder(
                        hovered ? DashSkin.accent(dark).opacity(0.55) : DashSkin.line(dark),
                        lineWidth: UIScale.pt(1))
            )
            .shadow(color: .black.opacity(hovered ? 0.1 : 0.04), radius: hovered ? 12 : 4, y: 3)
            .scaleEffect(hovered ? 1.008 : 1)
        }
        .buttonStyle(.edith(.borderless))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.16), value: hovered)
        .accessibilityLabel("Open \(project.name)")
    }

    private var artwork: some View {
        ZStack {
            Rectangle().fill(
                LinearGradient(
                    colors: [DashSkin.accent(dark).opacity(0.28), DashSkin.paper(dark)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            if let value = project.imageURL, let url = URL(string: value) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil {
                        projectMark
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                projectMark
            }
        }
        .frame(height: UIScale.pt(138))
        .clipped()
        .overlay(alignment: .bottomLeading) {
            Text(project.latestRun?.state.rawValue.uppercased() ?? "READY")
                .font(DashSkin.mono(9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white)
                .padding(.horizontal, UIScale.pt(8))
                .padding(.vertical, UIScale.pt(5))
                .background(.black.opacity(0.62), in: Capsule())
                .padding(UIScale.pt(10))
        }
    }

    private var projectMark: some View {
        Image(systemName: "globe.desk")
            .font(.system(size: UIScale.pt(34), weight: .light))
            .foregroundStyle(DashSkin.accent(dark))
    }

    private func cardMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
            Text(value).font(DashSkin.mono(12, weight: .semibold))
            Text(label).font(.system(size: UIScale.pt(9))).foregroundStyle(.tertiary)
        }
    }
}
