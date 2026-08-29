import AppKit
import EdithKit
import SwiftUI

enum HerdrSpaceKeyCommand: Equatable {
    case newTerminal
    case splitRight
    case splitDown
    case closeTab
    case closePane
    case selectTab(number: Int)
    case nextTab
    case previousTab

    static func resolve(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags
    ) -> HerdrSpaceKeyCommand? {
        let flags = modifiers.chordOnly
        if keyCode == 48, flags == .control { return .nextTab }
        if keyCode == 48, flags == [.control, .shift] { return .previousTab }
        if flags == .command {
            switch characters?.lowercased() {
            case "t": return .newTerminal
            case "d": return .splitRight
            case "w": return .closeTab
            default: break
            }
            if let characters, let number = Int(characters), (1...9).contains(number) {
                return .selectTab(number: number)
            }
        }
        if flags == [.command, .shift] {
            switch characters?.lowercased() {
            case "d": return .splitDown
            case "w": return .closePane
            default: break
            }
        }
        return nil
    }
}

@MainActor
enum HerdrSpaceWindow {
    static let identifier = NSUserInterfaceItemIdentifier("EdithHerdrSpaceWindow")

    private struct Entry {
        let window: NSWindow
        let model: HerdrSpaceWindowModel
    }

    private static var entries: [String: Entry] = [:]

    static var openIDs: Set<String> { Set(entries.keys) }

    static func has(_ spaceID: String) -> Bool { entries[spaceID] != nil }

    @discardableResult
    static func raise(_ spaceID: String) -> Bool {
        guard let entry = entries[spaceID] else { return false }
        entry.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    @discardableResult
    static func raise(containingAgent id: String) -> Bool {
        guard let entry = entries.values.first(where: { $0.model.selectAgent(id) }) else {
            return false
        }
        entry.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    static func open(space: HerdrAgentSpace, store: HerdrStore, launchEnabled: Bool) {
        if raise(space.id) { return }
        for agent in space.agents { HerdrAgentWindow.close(agent.id) }
        let model = HerdrSpaceWindowModel(space: space, store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.identifier = identifier
        window.title = "Space · \(space.title)"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 460)
        window.tabbingMode = .disallowed
        let hosting = NSHostingController(
            rootView: ZoomableRoot {
                HerdrSpaceView(model: model, store: store, launchEnabled: launchEnabled)
            })
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.setFrameAutosaveName("EdithHerdrSpaceWindow")
        if window.frame.origin == .zero { window.center() }
        window.delegate = HerdrSpaceWindowDelegate.shared
        entries[space.id] = Entry(window: window, model: model)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func perform(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
        in window: NSWindow?
    ) -> Bool {
        guard let entry = entry(for: window),
            let command = HerdrSpaceKeyCommand.resolve(
                characters: characters, keyCode: keyCode, modifiers: modifiers)
        else { return false }
        switch command {
        case .newTerminal:
            entry.model.addTerminal()
        case .splitRight:
            entry.model.split(.right)
        case .splitDown:
            entry.model.split(.bottom)
        case .closeTab:
            closeSelectedTab(in: entry)
        case .closePane:
            entry.model.closeFocusedPane()
        case let .selectTab(number):
            entry.model.selectTab(number: number)
        case .nextTab:
            entry.model.cycleTab(backwards: false)
        case .previousTab:
            entry.model.cycleTab(backwards: true)
        }
        return true
    }

    static func perform(_ command: WorkspaceKeyCommand, in window: NSWindow?) -> Bool {
        guard let entry = entry(for: window) else { return false }
        switch command {
        case .nextPaneTab, .nextTerminalTab:
            entry.model.cycleTab(backwards: false)
        case .previousPaneTab, .previousTerminalTab:
            entry.model.cycleTab(backwards: true)
        case .nextPane:
            entry.model.cyclePane(backwards: false)
        case .previousPane:
            entry.model.cyclePane(backwards: true)
        }
        return true
    }

    @discardableResult
    static func closeSelectedTab(in window: NSWindow?) -> Bool {
        guard let entry = entry(for: window) else { return false }
        closeSelectedTab(in: entry)
        return true
    }

    static func close(_ spaceID: String) {
        entries[spaceID]?.window.performClose(nil)
    }

    static func forget(_ window: NSWindow) {
        guard let match = entries.first(where: { $0.value.window === window }) else { return }
        match.value.model.stopAll()
        entries.removeValue(forKey: match.key)
    }

    private static func entry(for window: NSWindow?) -> Entry? {
        guard let window else { return nil }
        return entries.values.first { $0.window === window }
    }

    private static func closeSelectedTab(in entry: Entry) {
        if !entry.model.closeSelectedTab() {
            entry.window.performClose(nil)
        }
    }
}

@MainActor
final class HerdrSpaceWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = HerdrSpaceWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        HerdrSpaceWindow.forget(window)
    }
}

struct HerdrSpaceView: View {
    let model: HerdrSpaceWindowModel
    let store: HerdrStore
    var machines = MachinesModel.shared
    let launchEnabled: Bool

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(DashSkin.line(dark)).frame(height: 1)
            content
        }
        .background(DashSkin.paper(dark))
        .environment(\.terminalLaunchEnabled, launchEnabled)
    }

    private var toolbar: some View {
        HStack(spacing: UIScale.pt(10)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(5)) {
                    ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabItem(tab, number: index + 1)
                    }
                }
                .padding(.vertical, UIScale.pt(6))
            }
            .layoutPriority(1)
            terminalMenu
            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal, UIScale.pt(10))
        .frame(height: UIScale.pt(44))
        .background(DashSkin.paper2(dark))
    }

    private func tabItem(_ tab: HerdrSpaceTabModel, number: Int) -> some View {
        let selected = model.selectedTab?.id == tab.id
        return HStack(spacing: UIScale.pt(2)) {
            Button {
                model.selected = tab.id
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    if let agent = tab.agentTab?.agent {
                        HerdrKindMark(kind: agent.kind, size: UIScale.pt(11))
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: UIScale.pt(10), weight: .semibold))
                    }
                    Text(tab.title)
                        .font(.system(size: UIScale.pt(11.5), weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                .padding(.leading, UIScale.pt(9))
                .padding(.vertical, UIScale.pt(6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help(number <= 9 ? "\(tab.title) (⌘\(number))" : tab.title)

            Button {
                close(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: UIScale.pt(8.5), weight: .bold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(width: UIScale.pt(20), height: UIScale.pt(20))
            }
            .buttonStyle(.edith(.borderless))
            .help("Close \(tab.title)")
        }
        .padding(.trailing, UIScale.pt(3))
        .widgetBar(
            cornerRadius: 8,
            fill: selected ? DashSkin.paper(dark) : Color.clear,
            stroke: selected ? DashSkin.accent(dark).opacity(0.6) : DashSkin.line(dark)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var terminalMenu: some View {
        Menu {
            Button("New Terminal") { model.addTerminal() }
            if !model.contexts.isEmpty {
                Divider()
                ForEach(model.contexts) { context in
                    Button(context.title) { model.addTerminal(context: context) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: UIScale.pt(11), weight: .bold))
                .frame(width: UIScale.pt(24), height: UIScale.pt(24))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("New terminal (⌘T)")
        .accessibilityLabel("New terminal")
    }

    private var controls: some View {
        let tab = model.selectedTab
        let agent = tab?.agentTab
        return HStack(spacing: UIScale.pt(5)) {
            HStack(spacing: UIScale.pt(2)) {
                ForEach([HerdrAgentView.agent, .split, .diff], id: \.self) { mode in
                    Button {
                        tab?.setAgentView(mode)
                    } label: {
                        Label(mode.shortTitle, systemImage: mode.icon)
                            .font(.system(size: UIScale.pt(10), weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: UIScale.pt(22))
                    }
                    .buttonStyle(
                        .edith(
                            .borderless, selected: agent?.view == mode,
                            tint: DashSkin.accent(dark))
                    )
                    .disabled(agent == nil)
                    .help(mode.title)
                }
            }
            .padding(UIScale.pt(2))
            .frame(width: UIScale.pt(218))
            .widgetBar(
                cornerRadius: 8, fill: DashSkin.paper(dark),
                stroke: DashSkin.line(dark))

            controlButton(
                "rectangle.split.2x1", help: "Split right (⌘D)", enabled: tab != nil
            ) { model.split(.right) }
            controlButton(
                "rectangle.split.1x2", help: "Split down (⇧⌘D)", enabled: tab != nil
            ) { model.split(.bottom) }
            controlButton(
                "equal.square", help: "Even out panes", enabled: (tab?.paneCount ?? 0) > 1
            ) { tab?.equalize() }
            controlButton(
                "rectangle.split.2x1.fill", help: "Close focused pane (⇧⌘W)",
                enabled: (tab?.paneCount ?? 0) > 1
            ) { model.closeFocusedPane() }
            controlButton(
                "sidebar.right", help: store.detailOpen ? "Hide details" : "Show details",
                enabled: agent != nil, selected: store.detailOpen
            ) { store.detailOpen.toggle() }
        }
        .frame(width: UIScale.pt(418), alignment: .trailing)
    }

    private func controlButton(
        _ systemImage: String, help: String, enabled: Bool, selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .frame(width: UIScale.pt(24), height: UIScale.pt(24))
        }
        .buttonStyle(.edith(.toolbar, selected: selected, tint: DashSkin.accent(dark)))
        .disabled(!enabled)
        .help(help)
    }

    @ViewBuilder
    private var content: some View {
        if model.tabs.isEmpty {
            VStack(spacing: UIScale.pt(12)) {
                Image(systemName: "terminal")
                    .font(.system(size: UIScale.pt(28), weight: .light))
                Text("No terminals open")
                    .font(.system(size: UIScale.pt(15), weight: .semibold))
                Button("New Terminal") { model.addTerminal() }
                    .buttonStyle(.edith(.primary))
            }
            .foregroundStyle(DashSkin.inkSoft(dark))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                ForEach(model.tabs) { tab in
                    GeometryReader { proxy in
                        HerdrSpaceNodeView(
                            node: tab.layout.root, tab: tab, store: store,
                            machines: machines, size: proxy.size,
                            active: model.selectedTab?.id == tab.id, dark: dark,
                            launchEnabled: launchEnabled)
                    }
                    .opacity(model.selectedTab?.id == tab.id ? 1 : 0)
                    .allowsHitTesting(model.selectedTab?.id == tab.id)
                }
            }
        }
    }

    private func close(_ tab: HerdrSpaceTabModel) {
        model.selected = tab.id
        if !model.closeSelectedTab() { HerdrSpaceWindow.close(model.spaceID) }
    }
}

private struct HerdrSpaceNodeView: View {
    let node: LayoutNode
    let tab: HerdrSpaceTabModel
    let store: HerdrStore
    let machines: MachinesModel
    let size: CGSize
    let active: Bool
    let dark: Bool
    let launchEnabled: Bool

    private static let dividerWidth: CGFloat = 6

    var body: some View {
        switch node {
        case let .pane(pane):
            HerdrSpacePaneView(
                pane: pane, tab: tab, store: store, machines: machines,
                active: active, focused: active && tab.layout.focused == pane.id,
                dark: dark, launchEnabled: launchEnabled
            )
            .frame(width: size.width, height: size.height)
        case let .split(split):
            splitBody(split)
        }
    }

    @ViewBuilder
    private func splitBody(_ split: SplitNode) -> some View {
        let horizontal = split.axis == .horizontal
        let dividers = CGFloat(split.children.count - 1) * Self.dividerWidth
        let available = max(0, (horizontal ? size.width : size.height) - dividers)
        let layout =
            horizontal
            ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            ForEach(Array(split.children.enumerated()), id: \.element.id) { index, child in
                let length = max(60, available * split.ratios[index])
                HerdrSpaceNodeView(
                    node: child, tab: tab, store: store, machines: machines,
                    size: horizontal
                        ? CGSize(width: length, height: size.height)
                        : CGSize(width: size.width, height: length),
                    active: active, dark: dark, launchEnabled: launchEnabled
                )
                .frame(
                    width: horizontal ? length : size.width,
                    height: horizontal ? size.height : length)
                if index < split.children.count - 1 {
                    HerdrSpaceDivider(
                        axis: split.axis, dark: dark,
                        onDrag: { delta in
                            guard available > 0 else { return }
                            tab.resize(
                                splitID: split.id, index: index,
                                change: Double(delta / available))
                        },
                        onEqualize: { tab.equalize() })
                }
            }
        }
    }
}

private struct HerdrSpacePaneView: View {
    let pane: PaneNode
    let tab: HerdrSpaceTabModel
    let store: HerdrStore
    let machines: MachinesModel
    let active: Bool
    let focused: Bool
    let dark: Bool
    let launchEnabled: Bool

    var body: some View {
        Group {
            if let content = tab.content(for: pane), let target = selectedTarget {
                switch content {
                case let .agent(agent):
                    HerdrSessionView(
                        store: store, tab: agent, launchEnabled: launchEnabled,
                        presented: active, wantsFocus: focused,
                        onSetView: { tab.setAgentView($0) })
                case let .terminal(holder):
                    HerdrSpaceTerminalView(
                        target: target, holder: holder, machines: machines,
                        active: active, wantsFocus: focused)
                }
            } else {
                Color(nsColor: TerminalPalette.edith(dark: dark).background)
            }
        }
        .contentShape(Rectangle())
        .overlay {
            Rectangle()
                .strokeBorder(
                    focused ? DashSkin.accent(dark).opacity(0.72) : Color.clear,
                    lineWidth: UIScale.pt(1)
                )
                .allowsHitTesting(false)
        }
        .onTapGesture { tab.focus(pane.id) }
    }

    private var selectedTarget: PaneTarget? {
        pane.tabs.first { $0.id == pane.selected }?.target ?? pane.tabs.first?.target
    }
}

private struct HerdrSpaceTerminalView: View {
    let target: PaneTarget
    let holder: TerminalSessionHolder
    let machines: MachinesModel
    let active: Bool
    let wantsFocus: Bool

    @Environment(\.terminalLaunchEnabled) private var launchEnabled
    @Environment(\.colorScheme) private var scheme

    private var session: MachineSession { machines.session(for: target.machineID) }
    private var known: Bool { machines.knows(target.machineID) }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        Group {
            if known {
                MachineTerminalTab(
                    session: session, active: active, wantsFocus: wantsFocus,
                    context: MachineTerminalContext(startingDirectory: target.argument),
                    showsStatusBar: false,
                    holder: holder
                )
                .task(id: active) { connectIfNeeded() }
            } else {
                VStack(spacing: UIScale.pt(9)) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: UIScale.pt(24), weight: .light))
                    Text("Machine unavailable")
                        .font(.system(size: UIScale.pt(14), weight: .semibold))
                    Text("Add this machine in Edith to open its terminal.")
                        .font(.system(size: UIScale.pt(12)))
                }
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: TerminalPalette.edith(dark: dark).background))
            }
        }
    }

    private func connectIfNeeded() {
        guard active, launchEnabled, !session.isLocal else { return }
        if case .disconnected = session.state { session.start() }
    }
}

private struct HerdrSpaceDivider: View {
    let axis: SplitAxis
    let dark: Bool
    let onDrag: (CGFloat) -> Void
    let onEqualize: () -> Void

    @State private var hovering = false
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(hovering ? DashSkin.accent(dark).opacity(0.5) : DashSkin.line(dark))
            .frame(
                width: axis == .horizontal ? 6 : nil,
                height: axis == .horizontal ? nil : 6
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let travelled =
                            axis == .horizontal
                            ? value.translation.width : value.translation.height
                        let delta = travelled - lastTranslation
                        lastTranslation = travelled
                        onDrag(delta)
                    }
                    .onEnded { _ in lastTranslation = 0 }
            )
            .onTapGesture(count: 2, perform: onEqualize)
    }
}
