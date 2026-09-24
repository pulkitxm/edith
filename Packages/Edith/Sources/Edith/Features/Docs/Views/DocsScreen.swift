import EdithKit
import SwiftUI

enum DocsNavigation {
    static let navigationWidth = 244.0
    static let outlineWidth = 206.0
    static let readableWidth = 800.0
    static let outlineThreshold = 1060.0

    static func title(of page: DocsPage, in group: DocsGroup) -> String {
        if page.path == group.readmePath, !group.id.isEmpty { return "Overview" }
        guard let command = page.command else { return page.title }
        let root = group.pages.first { $0.path == group.readmePath }?.command
        if let root, command.hasPrefix(root + " ") {
            return String(command.dropFirst(root.count + 1))
        }
        return String(command.dropFirst(DocsCommandText.prefix.count))
    }

    static func visibleGroups(_ groups: [DocsGroup], filter: String) -> [(DocsGroup, [DocsPage])] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return groups.compactMap { group in
            guard !needle.isEmpty else { return (group, group.pages) }
            let matches = group.pages.filter { page in
                page.path.lowercased().contains(needle) || page.title.lowercased().contains(needle)
                    || group.title.lowercased().contains(needle)
            }
            return matches.isEmpty ? nil : (group, matches)
        }
    }

    static func percent(_ probability: Double) -> String {
        "\(Int((probability * 100).rounded()))%"
    }
}

struct DocsScreen: View {
    var browser: DocsBrowser = .shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @FocusState private var askFocused: Bool
    @FocusState private var filterFocused: Bool

    private var dark: Bool { scheme == .dark }

    var body: some View {
        @Bindable var browser = browser
        VStack(spacing: 0) {
            PageHeader(
                "Docs", trailing: { history },
                accessory: { askField(question: $browser.question) })
            Rectangle().fill(DashSkin.line(dark)).frame(height: 1)
            ZStack(alignment: .top) {
                content
                if browser.resultsVisible, let answer = browser.answer {
                    DocsAskResults(browser: browser, answer: answer, dark: dark)
                        .pageGutter(compact)
                        .padding(.top, UIScale.pt(6))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashSkin.paper(dark))
        .background(shortcuts)
        .navigationTitle("Docs")
        .task {
            guard automaticActionsEnabled else { return }
            await browser.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        @Bindable var browser = browser
        VStack(spacing: 0) {
            if let library = browser.library {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        DocsNavigator(
                            browser: browser, library: library, filter: $browser.filter,
                            filterFocused: $filterFocused, dark: dark
                        )
                        .frame(width: UIScale.pt(DocsNavigation.navigationWidth))
                        Rectangle().fill(DashSkin.line(dark)).frame(width: 1)
                        document(library, width: geometry.size.width)
                    }
                }
            } else {
                VStack(spacing: UIScale.pt(10)) {
                    ProgressView().controlSize(.small)
                    Text("Loading the reference")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var history: some View {
        HStack(spacing: UIScale.pt(14)) {
            Button {
                browser.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!browser.canGoBack)
            .help("Back (\u{2318}[)")
            .accessibilityLabel("Back")
            Button {
                browser.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!browser.canGoForward)
            .help("Forward (\u{2318}])")
            .accessibilityLabel("Forward")
        }
        .font(.system(size: UIScale.pt(14), weight: .semibold))
        .foregroundStyle(DashSkin.inkSoft(dark))
        .buttonStyle(.edith(.toolbar))
    }

    private func askField(question: Binding<String>) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: UIScale.pt(13), weight: .medium))
                .foregroundStyle(DashSkin.accent(dark))
            TextField(
                "Ask which command does something, like \u{201C}free up docker space on my server\u{201D}",
                text: question
            )
            .textFieldStyle(.plain)
            .font(.system(size: UIScale.pt(13.5)))
            .foregroundStyle(DashSkin.ink(dark))
            .focused($askFocused)
            .focusEffectDisabled()
            .onSubmit { Task { await browser.submit() } }
            .onChange(of: browser.question) { browser.questionChanged() }
            .onKeyPress(.downArrow) {
                browser.moveSelection(1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                browser.moveSelection(-1)
                return .handled
            }
            .onKeyPress(.escape) {
                if !browser.clearQuestion() { askFocused = false }
                return .handled
            }
            .onExitCommand {
                if !browser.clearQuestion() { askFocused = false }
            }
            if browser.asking {
                ProgressView().controlSize(.small)
            }
            Text("\u{2318}K")
                .font(DashSkin.mono(10.5, weight: .medium))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .padding(.horizontal, UIScale.pt(6))
                .padding(.vertical, UIScale.pt(2))
                .background(
                    DashSkin.line(dark).opacity(0.7),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(5)))
        }
        .edithFieldSurface(focused: askFocused)
    }

    private func document(_ library: DocsLibrary, width: Double) -> some View {
        let outline = width >= UIScale.pt(DocsNavigation.outlineThreshold)
        let column =
            width - UIScale.pt(DocsNavigation.navigationWidth)
            - (outline ? UIScale.pt(DocsNavigation.outlineWidth) : 0)
        let content = min(
            column - PageMetrics.gutter(compact) * 2, UIScale.pt(DocsNavigation.readableWidth))
        return HStack(spacing: 0) {
            if let page = browser.page {
                DocsPageView(
                    browser: browser, page: page,
                    group: library.groups.first { $0.id == page.group }, width: max(content, 280),
                    dark: dark)
                if outline {
                    DocsOutline(browser: browser, page: page, dark: dark)
                        .frame(width: UIScale.pt(DocsNavigation.outlineWidth))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var shortcuts: some View {
        ZStack {
            Button("") { filterFocused = true }.keyboardShortcut("f", modifiers: .command)
            Button("") { askFocused = true }.keyboardShortcut("k", modifiers: .command)
            Button("") { askFocused = true }.keyboardShortcut("l", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DocsAskResults: View {
    let browser: DocsBrowser
    let answer: DocsAnswer
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: UIScale.pt(8)) {
                Label(
                    answer.engine.label,
                    systemImage: answer.engine == .jev ? "sparkles" : "text.magnifyingglass"
                )
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(
                    answer.engine == .jev ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
                Text(answer.engine == .jev ? "picked by Jev" : "matched in the reference")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer(minLength: 0)
                Text("\u{2191}\u{2193} to move, Return to open, Esc to clear")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Button {
                    browser.hideResults()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: UIScale.pt(10), weight: .bold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                .buttonStyle(.edith(.borderless))
                .help("Hide the matches")
                .accessibilityLabel("Hide the matches")
            }
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(8))
            if answer.picks.isEmpty {
                Text("Nothing in the reference matches that. Try other words.")
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .padding(.horizontal, UIScale.pt(12))
                    .padding(.bottom, UIScale.pt(10))
            }
            ForEach(Array(answer.picks.enumerated()), id: \.element.id) { index, pick in
                Button {
                    browser.openPick(pick)
                } label: {
                    row(pick, selected: index == browser.selection)
                }
                .buttonStyle(
                    .edith(.row, selected: index == browser.selection, tint: DashSkin.accent(dark))
                )
                .padding(.horizontal, UIScale.pt(4))
            }
        }
        .padding(.bottom, UIScale.pt(4))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(10)).strokeBorder(DashSkin.line(dark)))
        .shadow(color: .black.opacity(dark ? 0.45 : 0.14), radius: UIScale.pt(18), y: UIScale.pt(8))
    }

    private func row(_ pick: DocsPick, selected: Bool) -> some View {
        HStack(alignment: .center, spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(pick.command.path)
                    .font(DashSkin.mono(12.5, weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(pick.command.summary)
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .lineLimit(1)
            }
            Spacer(minLength: UIScale.pt(8))
            Text(pick.command.location.path)
                .font(DashSkin.mono(10.5))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .lineLimit(1)
            HStack(spacing: UIScale.pt(6)) {
                Capsule()
                    .fill(DashSkin.line(dark))
                    .frame(width: UIScale.pt(44), height: UIScale.pt(4))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(DashSkin.accent(dark))
                            .frame(width: UIScale.pt(44) * pick.probability, height: UIScale.pt(4))
                    }
                Text(DocsNavigation.percent(pick.probability))
                    .font(DashSkin.mono(11, weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                    .frame(width: UIScale.pt(36), alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(DocsNavigation.percent(pick.probability)) confidence")
        }
        .contentShape(Rectangle())
    }
}

private struct DocsNavigator: View {
    let browser: DocsBrowser
    let library: DocsLibrary
    @Binding var filter: String
    var filterFocused: FocusState<Bool>.Binding
    let dark: Bool

    var body: some View {
        let filtering = !filter.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(spacing: 0) {
            SearchField(
                placeholder: "Filter pages  \u{2318}F", text: $filter, compact: true,
                focus: filterFocused
            )
            .padding(UIScale.pt(10))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: UIScale.pt(1)) {
                        ForEach(
                            DocsNavigation.visibleGroups(library.groups, filter: filter), id: \.0.id
                        ) {
                            group, pages in
                            let expanded = filtering || browser.expandedGroups.contains(group.id)
                            header(group, count: pages.count, expanded: expanded)
                            if expanded {
                                ForEach(pages) { page in
                                    pageRow(page, group: group)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, UIScale.pt(8))
                    .padding(.bottom, UIScale.pt(16))
                }
                .scrollIndicators(.automatic)
                .task(id: browser.revealSerial) {
                    try? await Task.sleep(for: .milliseconds(80))
                    proxy.scrollTo(browser.location.path, anchor: .center)
                }
            }
        }
        .background(DashSkin.paper(dark))
    }

    private func header(_ group: DocsGroup, count: Int, expanded: Bool) -> some View {
        Button {
            browser.toggle(group.id)
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: "chevron.right")
                    .font(.system(size: UIScale.pt(9), weight: .bold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: UIScale.pt(10))
                Text(group.title)
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(DashSkin.mono(10))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .padding(.horizontal, UIScale.pt(6))
            .padding(.vertical, UIScale.pt(5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .padding(.top, UIScale.pt(4))
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }

    private func pageRow(_ page: DocsPage, group: DocsGroup) -> some View {
        let selected = browser.location.path == page.path
        return Button {
            browser.open(DocsLocation(path: page.path), reveal: false)
        } label: {
            Text(DocsNavigation.title(of: page, in: group))
                .font(
                    page.command == nil
                        ? .system(size: UIScale.pt(12), weight: selected ? .semibold : .regular)
                        : DashSkin.mono(11.5, weight: selected ? .semibold : .regular)
                )
                .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, UIScale.pt(14))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.edith(.row, selected: selected, tint: DashSkin.accent(dark)))
        .help(page.path)
        .id(page.path)
    }
}

private struct DocsPageView: View {
    let browser: DocsBrowser
    let page: DocsPage
    let group: DocsGroup?
    let width: Double
    let dark: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    breadcrumb.padding(.top, UIScale.pt(20)).id("docs-top")
                    ForEach(DocsBlockRow.rows(page.blocks)) { row in
                        DocsBlockView(
                            block: row.block, width: width, dark: dark,
                            flashAnchor: browser.flashAnchor)
                    }
                }
                .frame(width: width, alignment: .leading)
                .padding(.bottom, UIScale.pt(48))
                .frame(maxWidth: .infinity)
            }
            .id(page.path)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    browser.follow(DocsLinkURL.link(for: url))
                    return .handled
                }
            )
            .task(id: browser.scroll) {
                let request = browser.scroll
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(request.anchor ?? "docs-top", anchor: .top)
                }
                guard request.anchor != nil else { return }
                try? await Task.sleep(for: .seconds(1.8))
                browser.endFlash(request.anchor)
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: UIScale.pt(6)) {
            Text(group.map { $0.id.isEmpty ? "ed reference" : $0.title } ?? "ed reference")
            Image(systemName: "chevron.right").font(.system(size: UIScale.pt(8), weight: .bold))
            Text(page.path)
            Spacer(minLength: 0)
        }
        .font(DashSkin.mono(10.5))
        .foregroundStyle(DashSkin.inkFaint(dark))
        .lineLimit(1)
    }
}

private struct DocsOutline: View {
    let browser: DocsBrowser
    let page: DocsPage
    let dark: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text("ON THIS PAGE")
                    .font(DashSkin.mono(10, weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .padding(.bottom, UIScale.pt(6))
                ForEach(page.outline) { heading in
                    let current = browser.location.anchor == heading.anchor
                    Button {
                        browser.open(DocsLocation(path: page.path, anchor: heading.anchor))
                    } label: {
                        Text(heading.text)
                            .font(
                                .system(
                                    size: UIScale.pt(11.5), weight: current ? .semibold : .regular)
                            )
                            .foregroundStyle(
                                current ? DashSkin.accent(dark) : DashSkin.inkSoft(dark)
                            )
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.leading, UIScale.pt(heading.level == 3 ? 12 : 0))
                            .padding(.vertical, UIScale.pt(3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.edith(.borderless))
                }
            }
            .padding(.top, UIScale.pt(22))
            .padding(.trailing, UIScale.pt(16))
        }
        .scrollIndicators(.never)
        .opacity(page.outline.isEmpty ? 0 : 1)
    }
}
