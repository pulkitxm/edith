import EdithExtensionSupport
import EdithExtensionUI
import EdithStudio
import SwiftUI

struct StudioProjectsView: View {
    let model: StudioModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: UIScale.pt(32)) {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    PageSectionHeader(
                        "Video projects",
                        subtitle: "Timeline edits with zooms, text and transitions."
                    ) {
                        Button {
                            model.newVideoProject()
                        } label: {
                            Label("New video project", systemImage: "plus")
                        }
                        .buttonStyle(.edith(.secondary))
                    }
                    if model.videoProjects.isEmpty {
                        StudioEmptyNote(
                            symbol: "film.stack",
                            text:
                                "No video projects yet. Choose New video project to import a clip and edit it on a timeline. Projects save automatically."
                        )
                    } else {
                        StudioListSurface {
                            ForEach(Array(model.videoProjects.enumerated()), id: \.element.id) {
                                index, project in
                                if index > 0 { Divider().opacity(0.5) }
                                StudioProjectRow(model: model, project: project)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    PageSectionHeader("Recent results", subtitle: "Files Studio created for you.")
                    if model.recent.isEmpty {
                        StudioEmptyNote(
                            symbol: "clock.arrow.circlepath",
                            text:
                                "Nothing yet. Open a tool from the Tools tab and run it, and the files it makes will be listed here with Show in Finder."
                        )
                    } else {
                        StudioListSurface {
                            ForEach(Array(model.recent.enumerated()), id: \.element.id) {
                                index, run in
                                if index > 0 { Divider().opacity(0.5) }
                                StudioRecentRow(model: model, run: run)
                            }
                        }
                    }
                }
            }
            .pageContent(compact)
            .pageScrollPosition("studio/projects")
        }
        .pageTask { model.refreshProjects() }
    }
}

struct StudioRecentRow: View {
    let model: StudioModel
    let run: StudioRecentRun

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            if let first = run.outputs.first {
                StudioThumbnail(url: first, side: 64, corner: 6)
                    .frame(width: UIScale.pt(40), height: UIScale.pt(40))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(
                    run.outputs.count == 1
                        ? run.outputs[0].lastPathComponent : "\(run.outputs.count) files"
                )
                .font(.edithText(.callout).weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                Text("\(run.title) · \(run.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.edithText(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: UIScale.pt(8))
            Button("Add to Files") { model.add(run.outputs) }
                .buttonStyle(.edith(.toolbar))
            Button("Show in Finder") { StudioFileActions.reveal(run.outputs, facade: model.facade) }
                .buttonStyle(.edith(.toolbar))
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(8))
    }
}

struct StudioEmptyNote: View {
    let symbol: String
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: UIScale.pt(12)) {
            Image(systemName: symbol)
                .font(.edithText(.body))
                .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
            Text(text)
                .font(.edithText(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DashSkin.paper2(scheme == .dark).opacity(0.6),
            in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }
}

struct StudioProjectRow: View {
    let model: StudioModel
    let project: VideoProject.Listing
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            Button {
                model.openVideoProject(project.url)
            } label: {
                HStack(spacing: UIScale.pt(10)) {
                    Image(systemName: "film.stack")
                        .font(.system(size: UIScale.pt(16)))
                        .foregroundStyle(DashSkin.accent(scheme == .dark))
                        .frame(width: UIScale.pt(40), height: UIScale.pt(40))
                        .background(
                            DashSkin.accent(scheme == .dark).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.title)
                            .font(.edithText(.callout).weight(.medium))
                            .foregroundStyle(DashSkin.ink(scheme == .dark))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.edithText(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help("Open \(project.title)")
            Button(role: .destructive) {
                model.trashProject(project)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.edith(.iconOnly))
            .help("Move \(project.title) to the Trash. You can restore it from there.")
            .accessibilityLabel("Move \(project.title) to Trash")
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(8))
        .contextMenu {
            Button("Open") { model.openVideoProject(project.url) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trashProject(project) }
        }
    }

    private var subtitle: String {
        let edited = "Edited \(project.modified.formatted(date: .abbreviated, time: .omitted))"
        return project.isOpenScreenLibrary ? "OpenScreen · \(edited)" : edited
    }
}
