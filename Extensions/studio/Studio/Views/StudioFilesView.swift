import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithStudio
import SwiftUI

struct StudioFilesView: View {
    let model: StudioModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if model.files.isEmpty {
            ScrollView {
                StudioDropHero(model: model)
                    .pageContent(compact)
            }
            .scrollIndicators(.never)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: UIScale.pt(16)) {
                        StudioFileFilters(model: model)
                        if model.visibleFiles.isEmpty {
                            ContentUnavailableView {
                                Label(
                                    "No files match this filter",
                                    edith: .filter)
                            } description: {
                                Text("Choose another file type or show all files.")
                            } actions: {
                                Button("Show all files") { model.kindFilter = nil }
                            }
                        } else {
                            StudioTileGrid(items: model.visibleFiles) { item in
                                StudioFileCard(model: model, item: item)
                            }
                        }
                    }
                    .pageContent(compact)
                    .pageScrollPosition("studio/files")
                }
                .scrollIndicators(.automatic)
                if !model.selection.isEmpty {
                    StudioSelectionBar(model: model)
                        .transition(
                            reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(
                Motion.animation(Motion.feedback, reduceMotion: reduceMotion),
                value: model.selection.isEmpty)
        }
    }
}

struct StudioDropHero: View {
    let model: StudioModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let steps = [
        PageGuideStep(
            icon: .addFilled, title: "Add files",
            detail: "Drop them here, choose them, paste, or scan with your iPhone."),
        PageGuideStep(
            icon: .adjust, title: "Pick a tool",
            detail: "Select files and choose a tool, or start from a popular one below."),
        PageGuideStep(
            icon: .success, title: "Get the result",
            detail: "Results are listed under Projects, ready to open or show in Finder."),
    ]

    private let popular = [
        "pdf.merge", "pdf.compress", "pdf.edit", "pdf.sign", "image.compress",
        "image.remove-background", "image.convert", "video.compress", "video.to-gif",
        "audio.convert", "pdf.redact", "document.to-pdf",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(32)) {
            VStack(spacing: UIScale.pt(16)) {
                PageGuideBadge(icon: .saveTo)
                Text("Drop a file here to get started")
                    .font(.edithText(.title2)).fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                Text(
                    "Studio edits, compresses, converts, merges and splits images, PDFs, videos, audio and documents. Everything runs on this Mac, nothing is uploaded."
                )
                .font(.edithText(.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: UIScale.pt(compact ? 460 : 540))
                PageGuideSteps(steps: Self.steps, columns: compact ? 1 : 3)
                    .frame(maxWidth: UIScale.pt(compact ? 460 : 700))
                let actions =
                    compact
                    ? AnyLayout(VStackLayout(spacing: UIScale.pt(8)))
                    : AnyLayout(HStackLayout(spacing: UIScale.pt(8)))
                actions {
                    Button {
                        model.chooseFiles()
                    } label: {
                        Label("Choose files", edith: .plus)
                    }
                    .buttonStyle(.edith(.primary))
                    Button {
                        model.paste()
                    } label: {
                        Label("Paste", edith: .clipboard)
                    }
                    .buttonStyle(.edith(.secondary))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, UIScale.pt(16))
            .padding(.vertical, UIScale.pt(32))
            .background(
                DashSkin.paper2(scheme == .dark),
                in: RoundedRectangle(cornerRadius: UIScale.pt(PageMetrics.cardCornerRadius))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(PageMetrics.cardCornerRadius))
                    .strokeBorder(
                        DashSkin.lineStrong(scheme == .dark),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                PageSectionHeader(
                    "Popular tools",
                    subtitle: "Pick one to start, then add the files it should work on.")
                StudioTileGrid(
                    items: popular.compactMap(StudioCatalog.tool),
                    maximumColumns: compact ? 1 : .max
                ) { tool in
                    StudioToolRow(tool: tool, environment: model.environment) {
                        model.open(tool, with: [])
                    }
                }
            }
        }
    }
}

struct StudioFileFilters: View {
    let model: StudioModel

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(8)) {
                    PageChip("All \(model.files.count)", active: model.kindFilter == nil) {
                        model.kindFilter = nil
                    }
                    .accessibilityAddTraits(model.kindFilter == nil ? .isSelected : [])
                    ForEach(model.kindsPresent, id: \.self) { kind in
                        PageChip(
                            "\(kind.pluralTitle) \(StudioLibraryQuery.kindCount(model.files, kind))",
                            active: model.kindFilter == kind
                        ) {
                            model.kindFilter = model.kindFilter == kind ? nil : kind
                        }
                        .accessibilityAddTraits(model.kindFilter == kind ? .isSelected : [])
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            Button("Select all") { model.selectAll() }
                .buttonStyle(.edith(.toolbar))
                .font(.edithText(.callout))
                .keyboardShortcut("a", modifiers: .command)
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.trailing, -UIScale.pt(StudioLayoutMetrics.toolbarInset))
        }
    }
}

struct StudioFileCard: View {
    @Environment(\.studioPrivacy) private var privacy
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
                .onDrag { NSItemProvider(object: item.url as NSURL) }
                .accessibilityLabel(
                    privacy?.hides(.ability("studio")) == true
                        ? "Select file" : "Select \(item.name)")
                HStack {
                    Button {
                        model.toggleSelection(item.url)
                    } label: {
                        EdithIconView(selected ? .success : .ring)
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
                    .font(.edithText(.callout).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(privacy?.hides(.ability("studio")) == true ? "File" : item.url.path)
                Text(StudioFileActions.describe(facts, kind: item.kind))
                    .font(.edithText(.caption))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .pageTask(id: item.url) { await model.loadFacts(for: item.url) }
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
                .font(.edithText(.caption).weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(
                    primary ? DashSkin.onAccent(scheme == .dark) : DashSkin.ink(scheme == .dark)
                )
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
            EdithIcon.more.image(size: 12, tint: .themeAccent)
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
        Button("Open") { StudioFileActions.open(item.url, facade: model.facade) }
        Button("Show in Finder") { StudioFileActions.reveal([item.url], facade: model.facade) }
        Divider()
        Button("Remove from Studio") { model.remove([item.url]) }
    }
}

struct StudioSelectionBar: View {
    let model: StudioModel
    @Environment(\.compactLayout) private var compact

    var body: some View {
        let urls = model.selectedURLs
        let suggestions = StudioCatalog.ranked(StudioToolGrouping.suggestions(for: urls))
        ViewThatFits(in: .horizontal) {
            bar(urls: urls, suggestions: suggestions, shown: 4, labelled: true)
            bar(urls: urls, suggestions: suggestions, shown: 2, labelled: true)
            bar(urls: urls, suggestions: suggestions, shown: 1, labelled: false)
            bar(urls: urls, suggestions: suggestions, shown: 0, labelled: false)
        }
        .pageGutter(compact)
        .padding(.vertical, UIScale.pt(10))
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func bar(
        urls: [URL], suggestions: [StudioTool], shown: Int, labelled: Bool
    ) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Text("\(urls.count) selected")
                .font(.edithText(.callout).weight(.semibold))
                .fixedSize()
            Divider().frame(height: UIScale.pt(18))
            ForEach(suggestions.prefix(shown)) { tool in
                Button {
                    model.open(tool, with: urls)
                } label: {
                    Label(tool.actionTitle, edith: tool.icon)
                        .lineLimit(1)
                }
                .buttonStyle(.edith(.secondary))
                .fixedSize()
            }
            if suggestions.count > shown {
                Menu(shown == 0 ? "Tools" : "More") {
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
            Button {
                StudioFileActions.reveal(urls, facade: model.facade)
            } label: {
                if labelled {
                    Text("Show in Finder")
                } else {
                    EdithIconView(.folder)
                }
            }
            .buttonStyle(.edith(labelled ? .toolbar : .iconOnly))
            .help("Show in Finder")
            .fixedSize()
            Button {
                model.remove(Set(urls))
            } label: {
                if labelled {
                    Text("Remove")
                } else {
                    EdithIconView(.removeFilled)
                }
            }
            .buttonStyle(.edith(labelled ? .toolbar : .iconOnly))
            .keyboardShortcut(.delete, modifiers: .command)
            .help("Remove from Studio. Files stay on your Mac.")
            .fixedSize()
            Button {
                model.selection.removeAll()
            } label: {
                EdithIconView(.close)
            }
            .buttonStyle(.edith(.iconOnly))
            .help("Clear selection")
            .accessibilityLabel("Clear selection")
            .padding(.trailing, -UIScale.pt(StudioLayoutMetrics.toolbarInset))
        }
        .font(.edithText(.callout))
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
