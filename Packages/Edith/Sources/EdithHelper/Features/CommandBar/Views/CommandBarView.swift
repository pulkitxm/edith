import AppKit
import EdithKit
import SwiftUI

struct CommandBarView: View {
    var model: CommandBarModel

    @FocusState private var searchFocused: Bool
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"

    var body: some View {
        VStack(spacing: 0) {
            search
            Divider().opacity(0.5)
            results
            Divider().opacity(0.5)
            footer
        }
        .frame(width: CommandBarController.width, height: CommandBarController.height)
        .onAppear { focusSearch() }
        .onReceive(NotificationCenter.default.publisher(for: CommandBarController.willShow)) { _ in
            focusSearch()
        }
    }

    private var search: some View {
        HStack(spacing: 12) {
            Image(systemName: "command")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(themeColor(themeName))
                .frame(width: 26)
            TextField(
                "Search commands, apps, files, settings, clipboard, or emoji",
                text: Bindable(model).query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 19, weight: .medium))
            .disableAutocorrection(true)
            .focused($searchFocused)
            .onKeyPress(.upArrow) {
                model.moveSelection(-1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                model.moveSelection(1)
                return .handled
            }
            .onKeyPress(.escape) {
                model.dismiss()
                return .handled
            }
            .onKeyPress(keys: [.return]) { press in
                model.executeSelected(reveal: press.modifiers.contains(.command))
                return .handled
            }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.edith(.borderless))
                .help("Clear search")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if model.items.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.items) { item in
                            result(item)
                                .id(item.id)
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selectedIndex) { _, _ in
                guard let item = model.selectedItem else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(item.id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.loadingApplications || model.searchingFiles {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
            }
            Text(
                model.searchingFiles
                    ? "Searching selected folders"
                    : model.loadingApplications ? "Loading applications" : "No matching commands"
            )
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private func result(_ item: CommandBarItem) -> some View {
        let selected = model.selectedItem?.id == item.id
        return Button {
            model.select(item.id)
            model.execute(item)
        } label: {
            HStack(spacing: 12) {
                icon(item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if let shortcut = item.shortcutLabel {
                    Text(shortcut)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if selected {
                    Text("↩")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .contentShape(Rectangle())
            .background(
                selected ? themeColor(themeName).opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.edith(.borderless))
        .onHover { hovering in
            if hovering { model.select(item.id) }
        }
        .contextMenu { resultMenu(item) }
    }

    @ViewBuilder
    private func resultMenu(_ item: CommandBarItem) -> some View {
        Button(item.pinned ? "Unpin Result" : "Pin Result") {
            model.togglePin(item)
        }
        Button("Hide Result") {
            model.hide(item)
        }
        if model.canAssignShortcut(item) {
            Menu("Assign Shortcut") {
                ForEach(CommandBarShortcutSlot.all) { slot in
                    Button {
                        model.assignShortcut(slot.shortcut, to: item)
                    } label: {
                        if item.shortcutLabel == slot.shortcut.label {
                            Label(slot.shortcut.label, systemImage: "checkmark")
                        } else {
                            Text(slot.shortcut.label)
                        }
                    }
                }
                if item.shortcutLabel != nil {
                    Divider()
                    Button("Remove Shortcut") {
                        model.assignShortcut(nil, to: item)
                    }
                }
            }
        }
        if case .application(let application, _) = item.kind {
            Divider()
            Button("Open") {
                model.execute(
                    CommandBarItem(
                        id: application.id, title: application.title,
                        subtitle: application.subtitle, symbolName: "app.fill",
                        keywords: [], sourceBias: 0,
                        kind: .application(application, .open)))
            }
            Button("Reveal in Finder") {
                model.execute(
                    CommandBarItem(
                        id: item.id, title: item.title, subtitle: item.subtitle,
                        symbolName: "folder", keywords: [], sourceBias: 0,
                        kind: .application(application, .reveal)))
            }
            if application.runningPID != nil {
                Button("Quit") {
                    model.execute(
                        CommandBarItem(
                            id: item.id, title: item.title, subtitle: item.subtitle,
                            symbolName: "xmark.circle", keywords: [], sourceBias: 0,
                            kind: .application(application, .quit)))
                }
                Button("Relaunch") {
                    model.execute(
                        CommandBarItem(
                            id: item.id, title: item.title, subtitle: item.subtitle,
                            symbolName: "arrow.clockwise", keywords: [], sourceBias: 0,
                            kind: .application(application, .relaunch)))
                }
            }
        }
    }

    @ViewBuilder
    private func icon(_ item: CommandBarItem) -> some View {
        switch item.kind {
        case .application(let application, _):
            Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
        case .file(let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: 22))
                .frame(width: 28, height: 28)
        case .clipboard(let entry):
            ClipboardThumbnailView(entry: entry, maxHeight: 28) {
                symbolIcon(item)
            }
            .frame(width: 28, height: 28)
        case .action, .answer, .systemSettings, .textUtility:
            symbolIcon(item)
        }
    }

    private func symbolIcon(_ item: CommandBarItem) -> some View {
        Image(systemName: item.symbolName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(themeColor(themeName))
            .frame(width: 28, height: 28)
            .background(
                themeColor(themeName).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("navigate", systemImage: "arrow.up.arrow.down")
            Label("open", systemImage: "return")
            if case .application = model.selectedItem?.kind {
                Text("⌘↩ reveal")
            }
            Spacer()
            Text(model.hasFileScopes ? "local metadata search" : "local search")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private func focusSearch() {
        DispatchQueue.main.async { searchFocused = true }
    }
}
