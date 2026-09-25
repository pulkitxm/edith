import AppKit
import EdithKit
import EdithStudio
import SwiftUI

struct StudioFilesView: View {
    let model: StudioModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: UIScale.pt(222), maximum: UIScale.pt(280)),
                spacing: UIScale.pt(14))
        ]
    }

    var body: some View {
        if model.files.isEmpty {
            ScrollView {
                StudioDropHero(model: model)
                    .pageContent(compact, width: .readable)
            }
            .scrollIndicators(.never)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                        StudioFileFilters(model: model)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: UIScale.pt(14)) {
                            ForEach(model.visibleFiles) { item in
                                StudioFileCard(model: model, item: item)
                            }
                        }
                    }
                    .pageContent(compact)
                }
                .scrollIndicators(.automatic)
                if !model.selection.isEmpty {
                    StudioSelectionBar(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.selection.isEmpty)
        }
    }
}

struct StudioDropHero: View {
    let model: StudioModel
    @Environment(\.colorScheme) private var scheme

    private let popular = [
        "pdf.merge", "pdf.compress", "pdf.edit", "pdf.sign", "image.compress",
        "image.remove-background", "image.convert", "video.compress", "video.to-gif",
        "audio.convert", "pdf.redact", "document.to-pdf",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(22)) {
            VStack(spacing: UIScale.pt(14)) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: UIScale.pt(40), weight: .ultraLight))
                    .foregroundStyle(DashSkin.accent(scheme == .dark))
                Text("Drop files here to start")
                    .font(.system(size: UIScale.pt(20), weight: .semibold))
                Text(
                    "Images, PDFs, videos, audio and documents. Edit, compress, convert, merge, split and more, all on this Mac."
                )
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: UIScale.pt(440))
                HStack(spacing: UIScale.pt(8)) {
                    Button {
                        model.chooseFiles()
                    } label: {
                        Label("Choose files", systemImage: "plus")
                    }
                    .buttonStyle(.edith(.primary))
                    Button {
                        model.paste()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.edith(.secondary))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UIScale.pt(40))
            .background(
                DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(18))
                    .strokeBorder(
                        DashSkin.lineStrong(scheme == .dark),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                Text("POPULAR TOOLS")
                    .font(DashSkin.mono(10, weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: UIScale.pt(200)), spacing: UIScale.pt(10))
                    ],
                    spacing: UIScale.pt(10)
                ) {
                    ForEach(popular, id: \.self) { id in
                        if let tool = StudioCatalog.tool(id) {
                            StudioToolRow(tool: tool, environment: model.environment) {
                                model.open(tool, with: [])
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, UIScale.pt(6))
    }
}

struct StudioFileFilters: View {
    let model: StudioModel

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            StudioChip(title: "All", count: model.files.count, selected: model.kindFilter == nil) {
                model.kindFilter = nil
            }
            ForEach(model.kindsPresent, id: \.self) { kind in
                StudioChip(
                    title: kind.pluralTitle, count: StudioLibraryQuery.kindCount(model.files, kind),
                    selected: model.kindFilter == kind
                ) {
                    model.kindFilter = model.kindFilter == kind ? nil : kind
                }
            }
            Spacer(minLength: UIScale.pt(8))
            Button("Select all") { model.selectAll() }
                .buttonStyle(.edith(.toolbar))
                .keyboardShortcut("a", modifiers: .command)
                .foregroundStyle(.secondary)
        }
    }
}

struct StudioFileCard: View {
    let model: StudioModel
    let item: StudioFileItem
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    private var selected: Bool { model.selection.contains(item.url) }
    private var facts: StudioFileFacts? { model.facts[item.url] }
    private var missing: Bool { facts?.exists == false }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(9)) {
            ZStack(alignment: .topLeading) {
                Button {
                    model.toggleSelection(item.url)
                } label: {
                    StudioThumbnail(url: item.url, side: 220)
                        .frame(height: UIScale.pt(132))
                        .opacity(missing ? 0.35 : 1)
                        .edithButtonTarget(.borderless)
                }
                .buttonStyle(.edith(.borderless))
                .accessibilityLabel("Select \(item.name)")
                HStack {
                    Button {
                        model.toggleSelection(item.url)
                    } label: {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: UIScale.pt(16)))
                            .foregroundStyle(
                                selected ? DashSkin.accent(scheme == .dark) : Color.secondary
                            )
                            .background(Circle().fill(DashSkin.paper2(scheme == .dark)).padding(1))
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .opacity(selected || hovering ? 1 : 0)
                    .accessibilityLabel(selected ? "Deselect" : "Select")
                    Spacer()
                    StudioKindBadge(kind: item.kind, label: missing ? "MISSING" : badge)
                }
                .padding(UIScale.pt(7))
            }
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(item.name)
                    .font(.system(size: UIScale.pt(12.5), weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
                Text(StudioFileActions.describe(facts, kind: item.kind))
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: UIScale.pt(4)) {
                ForEach(StudioQuickAction.allCases, id: \.self) { action in
                    if let tool = StudioCatalog.quickTool(action, for: item.kind) {
                        StudioQuickButton(title: action.title, primary: action == .edit) {
                            model.open(tool, with: [item.url])
                        }
                        .help(tool.title)
                    }
                }
                Spacer(minLength: 0)
                StudioFileMenu(model: model, item: item)
            }
            .disabled(missing)
        }
        .padding(UIScale.pt(10))
        .background(
            DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(14))
                .strokeBorder(
                    selected ? DashSkin.accent(scheme == .dark) : DashSkin.line(scheme == .dark),
                    lineWidth: selected ? 2 : 1)
        )
        .onHover { hovering = $0 }
        .contextMenu { StudioFileMenuItems(model: model, item: item) }
        .task(id: item.url) { await model.loadFacts(for: item.url) }
    }

    private var badge: String? {
        let ext = item.url.pathExtension.uppercased()
        return ext.isEmpty || ext.count > 5 ? nil : ext
    }
}

struct StudioQuickButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(primary ? Color.white : DashSkin.ink(scheme == .dark))
                .padding(.vertical, UIScale.pt(5))
                .padding(.horizontal, UIScale.pt(8))
                .background(
                    primary ? DashSkin.accent(scheme == .dark) : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                )
                .opacity(enabled ? 1 : 0.45)
                .edithButtonTarget(.borderless)
        }
        .buttonStyle(.edith(.borderless))
    }
}

struct StudioFileMenu: View {
    let model: StudioModel
    let item: StudioFileItem

    var body: some View {
        Menu {
            StudioFileMenuItems(model: model, item: item)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: UIScale.pt(12), weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, UIScale.pt(6))
        .help("All tools for this file")
    }
}

struct StudioFileMenuItems: View {
    let model: StudioModel
    let item: StudioFileItem

    var body: some View {
        let groups = StudioToolGrouping.byGroup(StudioCatalog.tools(accepting: [item.url]))
        ForEach(groups, id: \.group) { entry in
            Menu(entry.group.title) {
                ForEach(entry.tools) { tool in
                    Button(tool.title) { model.open(tool, with: [item.url]) }
                }
            }
        }
        Divider()
        Button("Open") { StudioFileActions.open(item.url) }
        Button("Show in Finder") { StudioFileActions.reveal([item.url]) }
        Divider()
        Button("Remove from Studio") { model.remove([item.url]) }
    }
}

struct StudioSelectionBar: View {
    let model: StudioModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let urls = model.selectedURLs
        let suggestions = StudioCatalog.ranked(StudioToolGrouping.suggestions(for: urls))
        HStack(spacing: UIScale.pt(10)) {
            Text("\(urls.count) selected")
                .font(.system(size: UIScale.pt(12.5), weight: .semibold))
            Divider().frame(height: UIScale.pt(18))
            ForEach(suggestions.prefix(4)) { tool in
                Button {
                    model.open(tool, with: urls)
                } label: {
                    Label(tool.actionTitle, systemImage: tool.symbolName)
                        .font(.system(size: UIScale.pt(12)))
                }
                .buttonStyle(.edith(.secondary))
            }
            if suggestions.count > 4 {
                Menu("More") {
                    ForEach(StudioToolGrouping.byGroup(suggestions), id: \.group) { entry in
                        Section(entry.group.title) {
                            ForEach(entry.tools) { tool in
                                Button(tool.title) { model.open(tool, with: urls) }
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer(minLength: UIScale.pt(8))
            Button("Show in Finder") { StudioFileActions.reveal(urls) }
                .buttonStyle(.edith(.toolbar))
            Button("Remove") { model.remove(Set(urls)) }
                .buttonStyle(.edith(.toolbar))
                .keyboardShortcut(.delete, modifiers: .command)
            Button {
                model.selection.removeAll()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.edith(.iconOnly))
            .help("Clear selection")
        }
        .padding(.horizontal, UIScale.pt(18))
        .padding(.vertical, UIScale.pt(10))
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

enum StudioToolGrouping {
    struct Entry {
        let group: StudioToolGroup
        let tools: [StudioTool]
    }

    static func byGroup(_ tools: [StudioTool]) -> [Entry] {
        StudioToolGroup.allCases.compactMap { group in
            let members = tools.filter { $0.group == group }
            return members.isEmpty ? nil : Entry(group: group, tools: members)
        }
    }

    static func suggestions(for urls: [URL]) -> [StudioTool] {
        let tools = StudioCatalog.tools(accepting: urls)
        let combining = tools.filter {
            if case .combine = $0.arity { return urls.count > 1 }
            return false
        }
        let rest = tools.filter { tool in !combining.contains(tool) && tool.style == .run }
        return combining + rest
    }
}

extension StudioLibraryQuery {
    static func kindCount(_ files: [StudioFileItem], _ kind: StudioKind) -> Int {
        files.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }
}
