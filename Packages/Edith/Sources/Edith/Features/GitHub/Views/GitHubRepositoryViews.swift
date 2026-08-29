import AppKit
import EdithCore
import EdithKit
import SwiftUI

struct GitHubRepositoryResourceView: View {
    let resource: GitHubRepositoryResource
    let route: GitHubRoute
    let navigate: (GitHubRoute, Bool) -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            switch resource {
            case let .repository(repository):
                GitHubRepositoryOverviewView(
                    repository: repository, host: route.host,
                    wide: proxy.size.width >= UIScale.pt(840), navigate: navigate)
            case let .directory(directory):
                GitHubDirectoryView(
                    directory: directory, host: route.host,
                    compact: proxy.size.width < UIScale.pt(700), navigate: navigate)
            case let .file(file):
                GitHubFileView(
                    file: file, route: route, compact: proxy.size.width < UIScale.pt(700),
                    navigate: navigate
                )
                .id("\(file.path)-\(file.sha)")
            }
        }
        .background(DashSkin.paper(scheme == .dark))
    }
}

private struct GitHubRepositoryOverviewView: View {
    let repository: GitHubRepositoryOverview
    let host: GitHubHost
    let wide: Bool
    let navigate: (GitHubRoute, Bool) -> Void

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                repositoryHeader
                if wide {
                    HStack(alignment: .top, spacing: UIScale.pt(16)) {
                        repositoryContents
                        about
                            .frame(width: UIScale.pt(245))
                    }
                } else {
                    repositoryContents
                    about
                }
            }
            .padding(UIScale.pt(wide ? 20 : 14))
            .frame(maxWidth: UIScale.pt(1_220), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var repositoryHeader: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(7)) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: UIScale.pt(15), weight: .medium))
                    .foregroundStyle(DashSkin.accent(dark))
                Text(repository.repository.owner)
                    .foregroundStyle(DashSkin.inkSoft(dark))
                Text("/")
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Text(repository.repository.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(DashSkin.ink(dark))
                GitHubBadge(repository.isPrivate ? "Private" : "Public", tint: .secondary)
                if repository.isArchived { GitHubBadge("Archived", tint: DashSkin.warn) }
                if repository.isFork { GitHubBadge("Fork", tint: DashSkin.accent(dark)) }
                Spacer(minLength: 0)
            }
            .font(.system(size: UIScale.pt(20)))
            if let description = repository.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .textSelection(.enabled)
            }
        }
    }

    private var repositoryContents: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(8)) {
                GitHubBranchMenu(
                    selected: repository.defaultBranch, branches: repository.branches
                ) { branch in
                    open(
                        GitHubRepositoryRoutes.directory(
                            host: host, repository: repository.repository, revision: branch.name,
                            path: ""))
                }
                Spacer(minLength: 0)
                Button {
                    open(
                        GitHubRoute(
                            host: host,
                            resource: .commits(
                                repository: repository.repository,
                                revision: repository.defaultBranch, path: [])))
                } label: {
                    Label("Commits", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.edith(.toolbar))
                .help("Show commit history")
            }
            .padding(UIScale.pt(11))
            Divider().opacity(0.5)
            if let commit = repository.latestCommit {
                latestCommit(commit)
                Divider().opacity(0.4)
            }
            GitHubRepositoryEntryList(
                entries: repository.entries, host: host, repository: repository.repository,
                revision: repository.defaultBranch, compact: !wide, navigate: navigate)
        }
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(11)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(11))
                .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1))
        }
    }

    private func latestCommit(_ commit: GitHubCommitSummary) -> some View {
        Button {
            open(
                GitHubRoute(
                    host: host,
                    resource: .commit(repository: repository.repository, oid: commit.sha)))
        } label: {
            HStack(spacing: UIScale.pt(9)) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: UIScale.pt(18)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(commit.subject)
                        .font(.system(size: UIScale.pt(11.5), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(1)
                    Text(commit.authorLogin ?? commit.authorName)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                Spacer(minLength: UIScale.pt(8))
                Text(commit.shortSHA)
                    .font(DashSkin.mono(9.5, weight: .medium))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                if let date = commit.authoredAt {
                    Text(GitHubRepositoryFormatting.relative(date))
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.row))
        .help("Open commit \(commit.shortSHA)")
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Text("About")
                .font(.system(size: UIScale.pt(13), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
            if let description = repository.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !repository.topics.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: UIScale.pt(72)), spacing: UIScale.pt(5))],
                    alignment: .leading, spacing: UIScale.pt(5)
                ) {
                    ForEach(repository.topics, id: \.self) { topic in
                        Text(topic)
                            .font(.system(size: UIScale.pt(9.5), weight: .medium))
                            .foregroundStyle(DashSkin.accentDeep(dark))
                            .padding(.horizontal, UIScale.pt(7))
                            .padding(.vertical, UIScale.pt(3))
                            .background(
                                DashSkin.accent(dark).opacity(0.12),
                                in: Capsule())
                    }
                }
            }
            Divider().opacity(0.5)
            GitHubAboutRow(symbol: "star", value: repository.stars, label: "stars")
            GitHubAboutRow(symbol: "tuningfork", value: repository.forks, label: "forks")
            GitHubAboutRow(
                symbol: "record.circle", value: repository.openIssues, label: "open issues")
            if let language = repository.language {
                GitHubAboutTextRow(
                    symbol: "chevron.left.forwardslash.chevron.right", text: language)
            }
            if let license = repository.license {
                GitHubAboutTextRow(symbol: "doc.text", text: license)
            }
            if let updatedAt = repository.updatedAt {
                GitHubAboutTextRow(
                    symbol: "clock",
                    text: "Updated \(GitHubRepositoryFormatting.relative(updatedAt))")
            }
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(11)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(11))
                .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1))
        }
    }

    private func open(_ destination: GitHubRoute) {
        navigate(destination, NSEvent.modifierFlags.contains(.command))
    }
}

private struct GitHubDirectoryView: View {
    let directory: GitHubDirectorySnapshot
    let host: GitHubHost
    let compact: Bool
    let navigate: (GitHubRoute, Bool) -> Void

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            GitHubPathHeader(
                host: host, repository: directory.repository, revision: directory.revision,
                path: directory.path, isFile: false, compact: compact, navigate: navigate)
            Divider().opacity(0.5)
            ScrollView {
                GitHubRepositoryEntryList(
                    entries: directory.entries, host: host, repository: directory.repository,
                    revision: directory.revision, compact: compact, navigate: navigate
                )
                .background(
                    DashSkin.paper2(dark),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(11))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(11))
                        .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1))
                }
                .padding(UIScale.pt(compact ? 12 : 18))
            }
        }
    }
}

private struct GitHubRepositoryEntryList: View {
    let entries: [GitHubRepositoryEntry]
    let host: GitHubHost
    let repository: GitHubRepositoryPath
    let revision: String
    let compact: Bool
    let navigate: (GitHubRoute, Bool) -> Void

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        LazyVStack(spacing: 0) {
            if entries.isEmpty {
                VStack(spacing: UIScale.pt(9)) {
                    Image(systemName: "folder")
                        .font(.system(size: UIScale.pt(24)))
                    Text("This directory is empty.")
                        .font(.system(size: UIScale.pt(12)))
                }
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(maxWidth: .infinity)
                .padding(.vertical, UIScale.pt(44))
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    entryRow(entry)
                    if index < entries.count - 1 { Divider().opacity(0.35) }
                }
            }
        }
    }

    private func entryRow(_ entry: GitHubRepositoryEntry) -> some View {
        let destination = GitHubRepositoryRoutes.entry(
            host: host, repository: repository, revision: revision, entry: entry)
        return Button {
            navigate(destination, NSEvent.modifierFlags.contains(.command))
        } label: {
            HStack(spacing: UIScale.pt(9)) {
                Image(systemName: GitHubRepositoryFormatting.symbol(entry.kind))
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    .foregroundStyle(
                        entry.kind == .directory
                            ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)
                    )
                    .frame(width: UIScale.pt(18))
                Text(entry.name)
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                Spacer(minLength: UIScale.pt(8))
                if !compact, entry.kind != .directory {
                    Text(ByteFormatter.string(Int64(entry.size)))
                        .font(DashSkin.mono(9.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                GitHubBadge(GitHubRepositoryFormatting.kind(entry.kind), tint: .secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: UIScale.pt(8), weight: .bold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.row))
        .contextMenu {
            Button("Open") { navigate(destination, false) }
            Button("Open in New Tab") { navigate(destination, true) }
            Divider()
            Button("Copy Link") { GitHubRepositoryPasteboard.copy(destination.url.absoluteString) }
            if let url = entry.url {
                Button("Open on GitHub") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

private struct GitHubPathHeader: View {
    let host: GitHubHost
    let repository: GitHubRepositoryPath
    let revision: String
    let path: String
    let isFile: Bool
    let compact: Bool
    let navigate: (GitHubRoute, Bool) -> Void

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var parts: [String] { path.split(separator: "/").map(String.init) }

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(4)) {
                    crumb(repository.repositoryName) {
                        GitHubRoute(host: host, resource: .repository(repository))
                    }
                    separator
                    crumb(revision) {
                        GitHubRepositoryRoutes.directory(
                            host: host, repository: repository, revision: revision, path: "")
                    }
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        separator
                        let terminal = index == parts.count - 1
                        if terminal, isFile {
                            Text(part)
                                .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                                .foregroundStyle(DashSkin.ink(dark))
                        } else {
                            crumb(part) {
                                GitHubRepositoryRoutes.directory(
                                    host: host, repository: repository, revision: revision,
                                    path: parts.prefix(index + 1).joined(separator: "/"))
                            }
                        }
                    }
                }
            }
            if !compact {
                Text(host.name)
                    .font(DashSkin.mono(9.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .padding(.horizontal, UIScale.pt(compact ? 11 : 15))
        .padding(.vertical, UIScale.pt(10))
        .background(.thinMaterial)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: UIScale.pt(7), weight: .bold))
            .foregroundStyle(DashSkin.inkFaint(dark))
    }

    private func crumb(_ label: String, route: @escaping () -> GitHubRoute) -> some View {
        Button {
            navigate(route(), NSEvent.modifierFlags.contains(.command))
        } label: {
            Text(label)
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(DashSkin.inkSoft(dark))
        }
        .buttonStyle(.edith(.borderless))
    }
}

private struct GitHubFileView: View {
    let file: GitHubFileSnapshot
    let route: GitHubRoute
    let compact: Bool
    let navigate: (GitHubRoute, Bool) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var wraps = false
    @State private var showsFind = false
    @State private var findQuery = ""
    @State private var matchCursor = 0
    @State private var selectedLines: GitHubLineSelection?
    @State private var highlightedLines: [AttributedString] = []

    init(
        file: GitHubFileSnapshot, route: GitHubRoute, compact: Bool,
        navigate: @escaping (GitHubRoute, Bool) -> Void
    ) {
        self.file = file
        self.route = route
        self.compact = compact
        self.navigate = navigate
        _selectedLines = State(initialValue: route.selectedLines)
    }

    private var dark: Bool { scheme == .dark }
    private var rawRoute: GitHubRoute {
        GitHubRepositoryRoutes.file(
            host: route.host, repository: file.repository, revision: file.revision,
            path: file.path, kind: .raw)
    }

    var body: some View {
        VStack(spacing: 0) {
            GitHubPathHeader(
                host: route.host, repository: file.repository, revision: file.revision,
                path: file.path, isFile: true, compact: compact, navigate: navigate)
            Divider().opacity(0.5)
            fileToolbar
            if showsFind { findBar }
            Divider().opacity(0.45)
            content
        }
        .task(id: "\(file.sha)-\(dark)") { await highlight() }
        .onChange(of: route.selectedLines) { _, selection in
            selectedLines = selection
        }
    }

    private var fileToolbar: some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: GitHubRepositoryFormatting.fileSymbol(file.presentation))
                .foregroundStyle(DashSkin.accent(dark))
            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                Text(file.name)
                    .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                if !compact {
                    Text("\(ByteFormatter.string(Int64(file.size))), \(file.lines.count) lines")
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            Spacer(minLength: UIScale.pt(6))
            if file.presentation == .text {
                Button {
                    wraps.toggle()
                } label: {
                    Image(systemName: "text.word.spacing")
                }
                .buttonStyle(.edith(.toolbar, selected: wraps))
                .help(wraps ? "Stop wrapping lines" : "Wrap lines")
                Button {
                    showsFind.toggle()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.edith(.toolbar, selected: showsFind))
                .help("Find in file")
            }
            if compact {
                Menu {
                    fileActions
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Button("Copy code", action: copyCode)
                    .buttonStyle(.edith(.toolbar))
                Button("Copy permalink", action: copyPermalink)
                    .buttonStyle(.edith(.toolbar))
                Button("Raw") {
                    navigate(rawRoute, NSEvent.modifierFlags.contains(.command))
                }
                .buttonStyle(.edith(.toolbar))
            }
        }
        .padding(.horizontal, UIScale.pt(compact ? 11 : 15))
        .padding(.vertical, UIScale.pt(8))
        .background(DashSkin.paper2(dark))
    }

    @ViewBuilder private var fileActions: some View {
        Button("Copy code", action: copyCode)
        Button("Copy permalink", action: copyPermalink)
        Divider()
        Button("Open raw") { navigate(rawRoute, false) }
        Button("Open raw in New Tab") { navigate(rawRoute, true) }
    }

    private var findBar: some View {
        HStack(spacing: UIScale.pt(8)) {
            SearchField(placeholder: "Find in file", text: $findQuery, compact: true)
                .frame(maxWidth: UIScale.pt(260))
                .onChange(of: findQuery) { _, _ in matchCursor = 0 }
            Text(matchSummary)
                .font(DashSkin.mono(9.5))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Button("Previous match", systemImage: "chevron.up") { moveMatch(-1) }
                .labelStyle(.iconOnly)
                .disabled(matchingLines.isEmpty)
            Button("Next match", systemImage: "chevron.down") { moveMatch(1) }
                .labelStyle(.iconOnly)
                .disabled(matchingLines.isEmpty)
            Button("Close find", systemImage: "xmark") { showsFind = false }
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.edith(.toolbar))
        .padding(.horizontal, UIScale.pt(compact ? 11 : 15))
        .padding(.vertical, UIScale.pt(7))
        .background(DashSkin.paper(dark))
    }

    @ViewBuilder private var content: some View {
        switch file.presentation {
        case .text:
            GitHubCodeLinesView(
                lines: file.lines, highlightedLines: highlightedLines, wraps: wraps,
                matchingLines: Set(matchingLines), selectedLines: selectedLines,
                scrollTarget: currentMatch ?? selectedLines?.firstLine, select: selectLine)
        case .image:
            unavailable(
                "Image file", "Open this image through its authenticated raw route.", "photo")
        case .pdf:
            unavailable(
                "PDF preview", "Open this PDF using its authenticated GitHub URL.", "doc.richtext")
        case .audio:
            unavailable(
                "Audio file", "Open this audio file on GitHub to play or download it.", "waveform")
        case .video:
            unavailable(
                "Video file", "Open this video file on GitHub to play or download it.",
                "play.rectangle")
        case .binary:
            unavailable(
                "Binary file", "This file cannot be displayed as text.", "doc.zipper")
        case .gitLFS:
            unavailable(
                "Git LFS object", "This file is stored through Git Large File Storage.",
                "externaldrive.badge.icloud")
        case .large:
            unavailable(
                "Large file", "This file is too large for the native preview.",
                "doc.badge.ellipsis")
        }
    }

    private func unavailable(_ title: String, _ message: String, _ symbol: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text("\(message) Size: \(ByteFormatter.string(Int64(file.size))).")
        } actions: {
            HStack {
                Button("Open raw") { navigate(rawRoute, false) }
                    .buttonStyle(.edith(.secondary))
                Button("Copy link", action: copyPermalink)
                    .buttonStyle(.edith(.borderless))
            }
        }
    }

    private var matchingLines: [Int] {
        guard !findQuery.isEmpty else { return [] }
        return file.lines.enumerated().compactMap { index, line in
            line.localizedCaseInsensitiveContains(findQuery) ? index + 1 : nil
        }
    }

    private var currentMatch: Int? {
        guard !matchingLines.isEmpty else { return nil }
        return matchingLines[min(matchCursor, matchingLines.count - 1)]
    }

    private var matchSummary: String {
        guard !findQuery.isEmpty else { return "" }
        guard !matchingLines.isEmpty else { return "No matches" }
        return "\(min(matchCursor + 1, matchingLines.count)) of \(matchingLines.count)"
    }

    private func moveMatch(_ offset: Int) {
        guard !matchingLines.isEmpty else { return }
        matchCursor = (matchCursor + offset + matchingLines.count) % matchingLines.count
    }

    private func selectLine(_ line: Int) {
        let selection: GitHubLineSelection
        if NSEvent.modifierFlags.contains(.shift), let anchor = selectedLines?.firstLine {
            selection = .range(min(anchor, line)...max(anchor, line))
        } else {
            selection = .single(line)
        }
        selectedLines = selection
        navigate(
            GitHubRepositoryRoutes.file(
                host: route.host, repository: file.repository, revision: file.revision,
                path: file.path, kind: .blob, lines: selection), false)
    }

    private func copyCode() {
        guard let text = file.text else { return }
        if let range = selectedLines?.range, !range.isEmpty {
            let selected = range.compactMap { index in
                file.lines.indices.contains(index - 1) ? file.lines[index - 1] : nil
            }
            GitHubRepositoryPasteboard.copy(selected.joined(separator: "\n"))
        } else {
            GitHubRepositoryPasteboard.copy(text)
        }
    }

    private func copyPermalink() {
        let destination = GitHubRepositoryRoutes.file(
            host: route.host, repository: file.repository, revision: file.revision,
            path: file.path, kind: .blob, lines: selectedLines)
        GitHubRepositoryPasteboard.copy(destination.url.absoluteString)
    }

    private func highlight() async {
        guard let text = file.text else {
            highlightedLines = []
            return
        }
        let rendered = await SyntaxHighlighting.shared.highlight(
            text: text, language: URL(fileURLWithPath: file.path).pathExtension, dark: dark)
        guard !Task.isCancelled, let rendered else {
            highlightedLines = []
            return
        }
        highlightedLines = GitHubRepositoryFormatting.lines(rendered, matching: file.lines)
    }
}

private struct GitHubCodeLinesView: View {
    let lines: [String]
    let highlightedLines: [AttributedString]
    let wraps: Bool
    let matchingLines: Set<Int>
    let selectedLines: GitHubLineSelection?
    let scrollTarget: Int?
    let select: (Int) -> Void

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if wraps {
                    ScrollView(.vertical) {
                        rows().frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            rows(minimumWidth: geometry.size.width)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(
                                    minHeight: geometry.size.height, alignment: .topLeading)
                        }
                    }
                }
            }
            .task(id: "\(wraps)-\(scrollTarget ?? 0)") {
                await Task.yield()
                guard !Task.isCancelled, let line = scrollTarget else { return }
                proxy.scrollTo(line, anchor: .center)
            }
        }
        .background(DashSkin.paper2(dark))
    }

    private func rows(minimumWidth: CGFloat? = nil) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let number = index + 1
                HStack(alignment: .top, spacing: 0) {
                    Button(String(number)) { select(number) }
                        .buttonStyle(.edith(.borderless))
                        .font(DashSkin.mono(9.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: UIScale.pt(50), alignment: .trailing)
                        .padding(.trailing, UIScale.pt(10))
                        .help("Select line \(number), shift-click to select a range")
                    Divider().opacity(0.35)
                    lineText(index, fallback: line)
                        .font(DashSkin.mono(11.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: !wraps, vertical: true)
                        .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
                        .padding(.leading, UIScale.pt(12))
                        .padding(.trailing, UIScale.pt(18))
                }
                .frame(minHeight: UIScale.pt(22), alignment: .top)
                .padding(.vertical, UIScale.pt(1))
                .frame(
                    minWidth: minimumWidth, maxWidth: wraps ? .infinity : nil,
                    alignment: .leading
                )
                .background(rowBackground(number))
                .id(number)
                .contextMenu {
                    Button("Copy line") { GitHubRepositoryPasteboard.copy(line) }
                    Button("Select line") { select(number) }
                }
            }
        }
        .padding(.vertical, UIScale.pt(8))
    }

    @ViewBuilder private func lineText(_ index: Int, fallback: String) -> some View {
        if highlightedLines.indices.contains(index) {
            Text(highlightedLines[index])
        } else {
            Text(fallback.isEmpty ? " " : fallback)
                .foregroundStyle(DashSkin.ink(dark))
        }
    }

    private func rowBackground(_ line: Int) -> Color {
        if selectedLines?.contains(line) == true { return DashSkin.accent(dark).opacity(0.18) }
        if matchingLines.contains(line) { return DashSkin.gold.opacity(0.12) }
        return .clear
    }
}

private struct GitHubBranchMenu: View {
    let selected: String
    let branches: [GitHubBranchSummary]
    let choose: (GitHubBranchSummary) -> Void

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        Menu {
            ForEach(branches) { branch in
                Button {
                    choose(branch)
                } label: {
                    if branch.name == selected {
                        Label(branch.name, systemImage: "checkmark")
                    } else {
                        Text(branch.name)
                    }
                }
            }
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: "arrow.triangle.branch")
                Text(selected).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: UIScale.pt(7), weight: .bold))
            }
            .font(.system(size: UIScale.pt(10.5), weight: .semibold))
            .foregroundStyle(DashSkin.ink(dark))
            .padding(.horizontal, UIScale.pt(9))
            .padding(.vertical, UIScale.pt(6))
            .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(7))
                    .strokeBorder(DashSkin.lineStrong(dark), lineWidth: UIScale.pt(1))
            }
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose a branch")
    }
}

private struct GitHubBadge: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: UIScale.pt(8.5), weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, UIScale.pt(6))
            .padding(.vertical, UIScale.pt(2))
            .background(tint.opacity(0.1), in: Capsule())
            .overlay { Capsule().strokeBorder(tint.opacity(0.24), lineWidth: UIScale.pt(1)) }
    }
}

private struct GitHubAboutRow: View {
    let symbol: String
    let value: Int
    let label: String

    var body: some View {
        GitHubAboutTextRow(
            symbol: symbol, text: "\(GitHubRepositoryFormatting.count(value)) \(label)")
    }
}

private struct GitHubAboutTextRow: View {
    let symbol: String
    let text: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: UIScale.pt(7)) {
            Image(systemName: symbol)
                .frame(width: UIScale.pt(14))
            Text(text).lineLimit(1)
        }
        .font(.system(size: UIScale.pt(10.5)))
        .foregroundStyle(DashSkin.inkSoft(scheme == .dark))
    }
}

private enum GitHubRepositoryRoutes {
    static func directory(
        host: GitHubHost, repository: GitHubRepositoryPath, revision: String, path: String
    ) -> GitHubRoute {
        GitHubRoute(
            host: host,
            resource: .content(
                repository: repository, kind: .tree,
                revisionPath: [revision] + segments(path), view: .automatic, lines: nil))
    }

    static func file(
        host: GitHubHost, repository: GitHubRepositoryPath, revision: String, path: String,
        kind: GitHubContentKind = .blob, lines: GitHubLineSelection? = nil
    ) -> GitHubRoute {
        GitHubRoute(
            host: host,
            resource: .content(
                repository: repository, kind: kind,
                revisionPath: [revision] + segments(path), view: .automatic, lines: lines))
    }

    static func entry(
        host: GitHubHost, repository: GitHubRepositoryPath, revision: String,
        entry: GitHubRepositoryEntry
    ) -> GitHubRoute {
        entry.kind == .directory
            ? directory(host: host, repository: repository, revision: revision, path: entry.path)
            : file(host: host, repository: repository, revision: revision, path: entry.path)
    }

    private static func segments(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}

private enum GitHubRepositoryFormatting {
    static func count(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func symbol(_ kind: GitHubRepositoryEntryKind) -> String {
        if kind == .directory { return "folder.fill" }
        if kind == .symlink { return "link" }
        if kind == .submodule { return "shippingbox" }
        return "doc.text"
    }

    static func kind(_ kind: GitHubRepositoryEntryKind) -> String {
        if kind == .directory { return "Folder" }
        if kind == .symlink { return "Link" }
        if kind == .submodule { return "Submodule" }
        return "File"
    }

    static func fileSymbol(_ presentation: GitHubFilePresentation) -> String {
        switch presentation {
        case .text: "doc.text"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .audio: "waveform"
        case .video: "play.rectangle"
        case .binary: "doc.zipper"
        case .gitLFS: "externaldrive.badge.icloud"
        case .large: "doc.badge.ellipsis"
        }
    }

    static func lines(_ value: NSAttributedString, matching lines: [String]) -> [AttributedString] {
        var result: [AttributedString] = []
        var location = 0
        for (index, line) in lines.enumerated() {
            let length = (line as NSString).length
            guard location + length <= value.length else { return result }
            let slice = value.attributedSubstring(from: NSRange(location: location, length: length))
            result.append(
                (try? AttributedString(slice, including: \.appKit)) ?? AttributedString(line))
            location += length
            if index < lines.count - 1 { location += 1 }
        }
        return result
    }
}

private enum GitHubRepositoryPasteboard {
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private extension GitHubRepositoryPath {
    var repositoryName: String { "\(owner)/\(name)" }
}

private extension GitHubRoute {
    var selectedLines: GitHubLineSelection? {
        guard case let .content(_, _, _, _, lines) = resource else { return nil }
        return lines
    }
}

private extension GitHubLineSelection {
    var firstLine: Int {
        switch self {
        case let .single(line): line
        case let .range(lines): lines.lowerBound
        }
    }

    var range: ClosedRange<Int> {
        switch self {
        case let .single(line): line...line
        case let .range(lines): lines
        }
    }

    func contains(_ line: Int) -> Bool {
        range.contains(line)
    }
}
