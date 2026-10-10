import EdithExtensionSupport
import Foundation
import GhosttyTerminal

extension HerdrStore {
    func makeTerminalUIPresentation(id: UUID, location: String, target: String, token: UUID?)
        -> OwnedTerminalUIPresentation
    {
        OwnedTerminalUIPresentation(
            id: id,
            holders: { [weak self] in
                self?.sceneTerminals(location: location, target: target, token: token) ?? []
            },
            action: { [weak self] in
                self?.terminalAction($0, location: location, target: target) ?? false
            },
            paneAction: { [weak self] action, holder in
                self?.terminalPaneAction(action, holder: holder, location: location, target: target)
            }, close: { [weak self] in self?.stopRendering() })
    }

    private func sceneTerminals(location: String, target: String, token: UUID?)
        -> [TerminalSessionHolder]
    {
        if location == "main" {
            return sessions.flatMap { [$0.holder, $0.quinjet.holder] }
                + terminalPanels.terminals.values.map(\.holder)
        }
        guard let token,
            uiPresentations.contains(where: {
                $0.presented && $0.matches(location: location, target: target, token: token)
            })
        else { return [] }
        if location == "herdr.space" { return uiSpaces[target]?.tabs.flatMap(\.holders) ?? [] }
        if location == "herdr.agent", let agent = detachedTab(id: target) {
            return [agent.holder, agent.quinjet.holder]
        }
        return []
    }

    private func terminalAction(
        _ action: OwnedTerminalUIEvent.Action, location: String, target: String
    ) -> Bool {
        if location == "herdr.space", let model = uiSpaces[target] {
            switch action {
            case .newTab: _ = model.addTerminal()
            case .closeTab: return model.closeSelectedTab()
            case .nextTab: return model.cycleTab(backwards: false)
            case .previousTab: return model.cycleTab(backwards: true)
            default: return false
            }
            return true
        }
        if location == "herdr.agent", action == .closeTab {
            closePresentation(kind: "agent", id: target)
            return true
        }
        guard location == "main" else { return false }
        switch action {
        case .newTab: _ = openTerminalNow(in: selectedTab)
        case .closeTab: return closeFocusedTab()
        case .nextTab: return cycleTab(backwards: false)
        case .previousTab: return cycleTab(backwards: true)
        default: return false
        }
        return true
    }

    private func terminalPaneAction(
        _ action: GhosttyPaneAction, holder: TerminalSessionHolder,
        location: String, target: String
    ) {
        if location == "herdr.space", let model = uiSpaces[target], let tab = model.selectedTab,
            tab.holders.contains(where: { $0 === holder })
        {
            model.terminalPaneAction(action, holder: holder)
            return
        }
        guard location == "main" else { return }
        switch action {
        case .newTab: _ = terminalAction(.newTab, location: location, target: target)
        case .selectTab(let index):
            if index == -1 {
                _ = cycleTab(backwards: true)
            } else if index == -2 {
                _ = cycleTab(backwards: false)
            } else if index == -3 {
                selectTab(number: orderedTabIDs.count)
            } else if index > 0 {
                selectTab(number: Int(index))
            }
        case .split(let direction):
            guard let tab = currentTab, let side = terminalInsertSide(direction.rawValue) else {
                return
            }
            _ = splitAgent(tab.focused, side: side)
        case .focus(let direction):
            if direction == .previous || direction == .next {
                cycleFocus(backwards: direction == .previous)
            } else if let side = terminalInsertSide(direction.rawValue) {
                focusNeighbor(toward: side)
            }
        case .equalize: if let tab = currentTab { equalize(tab.id) }
        case .toggleZoom: if let tab = currentTab { toggleZoom(tab.focused) }
        case .resize(let direction, let amount):
            guard let tab = currentTab, let side = terminalInsertSide(direction.rawValue),
                amount > 0,
                let rect = tab.layout.frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))[
                    tab.focused]
            else { return }
            let horizontal = side.axis == .horizontal
            let edge =
                horizontal
                ? (side.isBefore ? rect.minX : rect.maxX) : (side.isBefore ? rect.minY : rect.maxY)
            let dividers = tab.layout.dividers(
                in: CGRect(x: 0, y: 0, width: 8192, height: 8192), gap: 0
            )
            .filter {
                $0.axis == side.axis
                    && abs((horizontal ? $0.rect.midX : $0.rect.midY) - edge) < 0.0001
            }
            guard let divider = dividers.min(by: { $0.span < $1.span }), divider.span > 0 else {
                return
            }
            let cells = Double(horizontal ? holder.terminalColumns : holder.terminalRows)
            let delta =
                Double(amount) * Double(horizontal ? rect.width : rect.height) / max(1, cells)
                / Double(divider.span)
            resize(
                tab.id, split: divider.splitID, index: divider.index,
                by: side.isBefore ? -delta : delta)
        }
    }
}

extension HerdrSpaceWindowModel {
    func terminalPaneAction(_ action: GhosttyPaneAction, holder: TerminalSessionHolder) {
        guard let tab = selectedTab, tab.holders.contains(where: { $0 === holder }) else { return }
        switch action {
        case .newTab: _ = addTerminal()
        case .selectTab(let index):
            if index == -1 {
                _ = cycleTab(backwards: true)
            } else if index == -2 {
                _ = cycleTab(backwards: false)
            } else if index == -3 {
                _ = selectTab(number: tabs.count)
            } else if index > 0 {
                _ = selectTab(number: Int(index))
            }
        case .split(let direction):
            if let side = terminalInsertSide(direction.rawValue) { split(side) }
        case .focus(let direction):
            if direction == .previous || direction == .next {
                _ = cyclePane(backwards: direction == .previous); return
            }
            guard let side = terminalInsertSide(direction.rawValue) else { return }
            var frames: [UUID: CGRect] = [:]
            WorkspaceGeometry.frames(
                node: tab.layout.root, in: CGRect(x: 0, y: 0, width: 1, height: 1), gap: 0,
                into: &frames)
            guard let origin = frames[tab.layout.focused] else { return }
            let horizontal = side.axis == .horizontal
            let current = horizontal ? origin.midX : origin.midY
            let candidates = frames.filter { id, rect in
                id != tab.layout.focused
                    && (side.isBefore
                        ? (horizontal ? rect.midX : rect.midY) < current
                        : (horizontal ? rect.midX : rect.midY) > current)
            }
            if let next = candidates.min(by: {
                abs($0.value.midX - origin.midX) + abs($0.value.midY - origin.midY)
                    < abs($1.value.midX - origin.midX) + abs($1.value.midY - origin.midY)
            }) {
                tab.focus(next.key)
            }
        case .equalize: tab.equalize()
        case .toggleZoom:
            tab.layout.maximized =
                tab.layout.maximized == tab.layout.focused ? nil : tab.layout.focused
        case .resize(let direction, let amount):
            guard let side = terminalInsertSide(direction.rawValue), amount > 0 else { return }
            resizeTerminal(tab.layout.root, tab: tab, side: side, amount: amount, holder: holder)
        }
    }

    private func resizeTerminal(
        _ node: LayoutNode, tab: HerdrSpaceTabModel, side: InsertSide,
        amount: UInt16, holder: TerminalSessionHolder
    ) {
        guard case .split(let split) = node,
            let index = split.children.firstIndex(where: { $0.pane(tab.layout.focused) != nil })
        else { return }
        if case .split(let child) = split.children[index], child.axis == side.axis {
            resizeTerminal(
                split.children[index], tab: tab, side: side, amount: amount, holder: holder)
            return
        }
        guard split.axis == side.axis, split.children.count > 1 else {
            resizeTerminal(
                split.children[index], tab: tab, side: side, amount: amount, holder: holder)
            return
        }
        let divider = side.isBefore && index > 0 ? index - 1 : min(index, split.children.count - 2)
        let cells = Double(side.axis == .horizontal ? holder.terminalColumns : holder.terminalRows)
        let delta = Double(amount) * split.ratios[index] / max(1, cells)
        tab.resize(splitID: split.id, index: divider, change: side.isBefore ? -delta : delta)
    }
}

private func terminalInsertSide(_ value: String) -> InsertSide? {
    switch value {
    case "up": return .top
    case "down": return .bottom
    default: return InsertSide(rawValue: value)
    }
}
