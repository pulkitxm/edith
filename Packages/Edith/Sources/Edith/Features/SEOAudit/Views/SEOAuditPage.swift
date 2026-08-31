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
                    Text("Crawl every page, inspect every share card, and keep each run local.")
                        .font(.system(size: UIScale.pt(13)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
                newProjectCard
                    .pageGutter(compact)
                projects
                    .pageGutter(compact)
            }
            .padding(.bottom, UIScale.pt(PageMetrics.bottom))
        }
    }

    private var newProjectCard: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack(alignment: .center, spacing: UIScale.pt(12)) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: UIScale.pt(20), weight: .medium))
                    .foregroundStyle(DashSkin.accent(dark))
                    .frame(width: UIScale.pt(34), height: UIScale.pt(34))
                    .background(DashSkin.accent(dark).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("Start with a URL")
                        .font(.system(size: UIScale.pt(16), weight: .semibold))
                    Text("Edith finds robots.txt, sitemap indexes, and every page below them.")
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: UIScale.pt(10)) {
                    fields; startButton
                }
                VStack(spacing: UIScale.pt(10)) {
                    fields; startButton.frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: UIScale.pt(10)) {
                Toggle("Run Lighthouse for every page", isOn: $model.lighthouseEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                    .disabled(!model.lighthouseAvailable)
                if !model.lighthouseAvailable {
                    Text("Lighthouse is not on PATH")
                        .font(.system(size: UIScale.pt(10.5), weight: .medium))
                        .foregroundStyle(DashSkin.warn)
                }
            }
        }
        .padding(UIScale.pt(18))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(16)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(16))
                .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1)))
    }

    private var fields: some View {
        HStack(spacing: UIScale.pt(10)) {
            EdithTextField(
                placeholder: "localhost:3000 or example.com", text: $model.input,
                icon: "link", clearable: true, onSubmit: model.beginNewProject
            )
            .frame(maxWidth: .infinity)
            EdithTextField(
                placeholder: "Project name (optional)", text: $model.projectName,
                icon: "folder"
            )
            .frame(maxWidth: compact ? .infinity : UIScale.pt(230))
        }
    }

    private var startButton: some View {
        Button(action: model.beginNewProject) {
            Label("Start audit", systemImage: "arrow.right")
                .frame(minWidth: UIScale.pt(100))
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
