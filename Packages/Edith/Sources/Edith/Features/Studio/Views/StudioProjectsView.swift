import EdithKit
import EdithStudio
import SwiftUI

struct StudioProjectsView: View {
    let model: StudioModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(22)) {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
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
                            text: "Edit a video from Files, or start a new project to see it here.")
                    } else {
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: UIScale.pt(220)), spacing: UIScale.pt(12))
                            ],
                            alignment: .leading, spacing: UIScale.pt(12)
                        ) {
                            ForEach(model.videoProjects) { project in
                                Button {
                                    model.openVideoProject(project.url)
                                } label: {
                                    HStack(spacing: UIScale.pt(10)) {
                                        Image(systemName: "film.stack")
                                            .font(.system(size: UIScale.pt(16)))
                                            .foregroundStyle(StudioPalette.tint(for: .video))
                                            .frame(width: UIScale.pt(34), height: UIScale.pt(34))
                                            .background(
                                                StudioPalette.tint(for: .video).opacity(0.12),
                                                in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(project.title)
                                                .font(
                                                    .system(
                                                        size: UIScale.pt(12.5), weight: .semibold)
                                                )
                                                .foregroundStyle(DashSkin.ink(scheme == .dark))
                                                .lineLimit(1)
                                            Text(
                                                project.isOpenScreenLibrary
                                                    ? "OpenScreen" : "Studio"
                                            )
                                            .font(.system(size: UIScale.pt(10.5)))
                                            .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(UIScale.pt(10))
                                    .background(
                                        DashSkin.paper2(scheme == .dark),
                                        in: RoundedRectangle(cornerRadius: UIScale.pt(10))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: UIScale.pt(10))
                                            .strokeBorder(DashSkin.line(scheme == .dark))
                                    )
                                    .edithButtonTarget(.borderless)
                                }
                                .buttonStyle(.edith(.borderless))
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    PageSectionHeader("Recent results", subtitle: "Files Studio created for you.")
                    if model.recent.isEmpty {
                        StudioEmptyNote(
                            symbol: "clock.arrow.circlepath",
                            text: "Run a tool or save from an editor and the results appear here.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.recent.enumerated()), id: \.element.id) {
                                index, run in
                                if index > 0 { Divider().opacity(0.5) }
                                StudioRecentRow(model: model, run: run)
                            }
                        }
                        .background(
                            DashSkin.paper2(scheme == .dark),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                                DashSkin.line(scheme == .dark)))
                    }
                }
            }
            .pageContent(compact, width: .readable)
        }
        .task { model.refreshProjects() }
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
                .font(.system(size: UIScale.pt(12.5), weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                Text("\(run.title) · \(run.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: UIScale.pt(8))
            Button("Add to Files") { model.add(run.outputs) }
                .buttonStyle(.edith(.toolbar))
            Button("Show in Finder") { StudioFileActions.reveal(run.outputs) }
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
        HStack(spacing: UIScale.pt(10)) {
            Image(systemName: symbol)
                .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
            Text(text)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DashSkin.paper2(scheme == .dark).opacity(0.6),
            in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }
}
