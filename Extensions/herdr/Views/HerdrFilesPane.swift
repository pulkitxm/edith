import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HerdrFilesPane: View {
    let browser: HerdrFilesBrowser
    var autoFocus = true
    var onFocus: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(DashSkin.paper(dark))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: focused) { _, isFocused in
            if isFocused { onFocus?() }
        }
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
        .task(id: ObjectIdentifier(browser)) {
            await browser.start()
            if autoFocus { focused = true }
        }
    }

    private var toolbar: some View {
        HStack(spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(2)) {
                Button {
                    browser.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!browser.canGoBack)
                .help("Back (⌘[)")
                Button {
                    browser.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!browser.canGoForward)
                .help("Forward (⌘])")
                Button {
                    browser.goUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!browser.canGoUp)
                .help("Enclosing folder (⌘↑)")
                Button {
                    browser.goHome()
                } label: {
                    Image(systemName: "house")
                }
                .help("Home")
            }
            .buttonStyle(.edith(.toolbar))

            Text(browser.path)
                .font(DashSkin.mono(10.5))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Toggle(isOn: Bindable(browser).showHidden) {
                Image(systemName: "eye")
            }
            .toggleStyle(.button)
            .buttonStyle(.edith(.toolbar))
            .help("Show hidden files")

            Button {
                browser.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.edith(.toolbar))
            .help("Reload")
        }
        .padding(.horizontal, UIScale.pt(10))
        .padding(.vertical, UIScale.pt(6))
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var content: some View {
        if let message = browser.errorMessage {
            Text(message)
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(DashSkin.warn)
                .multilineTextAlignment(.center)
                .padding(UIScale.pt(16))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if browser.visibleEntries.isEmpty {
            Text(browser.loading ? "Loading…" : "This folder is empty.")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(browser.visibleEntries) { entry in
                        HerdrFilesRow(
                            entry: entry, selected: browser.selection.contains(entry.path),
                            dark: dark,
                            onClick: { extending in
                                browser.click(entry, extending: extending)
                                focused = true
                            },
                            onOpen: { browser.open(entry) }
                        )
                        .id(entry.path)
                    }
                }
            }
            .onChange(of: browser.scrollTarget, initial: true) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .upArrow where command:
            browser.goUp()
        case .upArrow:
            browser.moveSelection(by: -1)
        case .downArrow:
            browser.moveSelection(by: 1)
        case .return:
            browser.openSelection()
        default:
            guard command else { return .ignored }
            switch press.characters {
            case "[": browser.goBack()
            case "]": browser.goForward()
            default: return .ignored
            }
        }
        return .handled
    }
}

private struct HerdrFilesRow: View {
    let entry: RemoteFileEntry
    let selected: Bool
    let dark: Bool
    let onClick: (Bool) -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(entry.isDirectory ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(18))
            Text(entry.name)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isDirectory ? "\u{2014}" : sizeText)
                .font(DashSkin.mono(10))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(64), alignment: .trailing)
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(4))
        .background(
            selected
                ? DashSkin.accent(dark).opacity(0.22)
                : (hovering ? DashSkin.inkFaint(dark).opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture {
            onClick(NSEvent.modifierFlags.contains(.command))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var symbol: String {
        switch entry.kind {
        case .directory: "folder.fill"
        case .symlink: "arrow.turn.up.right"
        case .file, .other: "doc"
        }
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file)
    }
}
