import EdithKit
import Foundation
import Testing

@testable import Edith

@Suite struct WorkspaceFocusRouteTests {
    @Test func valueNamesTheFocusedPaneAndItsSelectedTab() {
        let sample = WorkspaceFocusSample()
        #expect(
            WorkspaceFocusRoute.value(sample.layout)
                == "\(sample.paneA.uuidString)~\(sample.tabA.uuidString)")
        #expect(
            WorkspaceFocusRoute.accepts(
                sample.focus(sample.paneA, sample.tabA2), layout: sample.layout))
        #expect(
            !WorkspaceFocusRoute.accepts(
                sample.focus(sample.paneA, sample.tabB), layout: sample.layout))
        #expect(!WorkspaceFocusRoute.accepts("not-a-pane", layout: sample.layout))
    }

    @Test func applyRestoresPaneFocusAndTheSelectedTab() {
        let sample = WorkspaceFocusSample()
        var layout = sample.layout
        #expect(WorkspaceFocusRoute.apply(sample.focus(sample.paneA, sample.tabA2), to: &layout))
        #expect(layout.focused == sample.paneA)
        #expect(layout.root.pane(sample.paneA)?.selected == sample.tabA2)
        #expect(WorkspaceFocusRoute.apply(sample.focus(sample.paneB, sample.tabB), to: &layout))
        #expect(layout.focused == sample.paneB)
        #expect(layout.root.pane(sample.paneB)?.selected == sample.tabB)
        #expect(layout.root.pane(sample.paneA)?.selected == sample.tabA2)
        var unchanged = layout
        #expect(!WorkspaceFocusRoute.apply(sample.focus(sample.paneA, UUID()), to: &unchanged))
        #expect(unchanged == layout)
    }

    @Test func spaceValueRoundTripsTheTabPaneAndSelectedTab() {
        let sample = WorkspaceFocusSample()
        let tabID = UUID()
        let raw = WorkspaceFocusRoute.spaceValue(tabID: tabID, layout: sample.layout)
        let decoded = WorkspaceFocusRoute.decodeSpace(raw)
        #expect(decoded?.tabID == tabID)
        #expect(decoded?.focus == WorkspaceFocusRoute.value(sample.layout))
        #expect(WorkspaceFocusRoute.decodeSpace(tabID.uuidString) == nil)
        #expect(WorkspaceFocusRoute.decodeSpace(WorkspaceFocusRoute.value(sample.layout)) == nil)
    }
}

@MainActor
@Suite struct WorkspaceFocusHistoryTests {
    @Test func switchingTabsAndPanesRecordsHistoryAndRestoresBoth() {
        let sample = WorkspaceFocusSample()
        let host = WorkspaceRouteHost(layout: sample.layout)
        host.sync()
        #expect(host.router.location == "workspace/\(sample.focus(sample.paneA, sample.tabA))")
        #expect(host.router.history.entries.count == 1)

        host.layout = sample.selecting(sample.paneA, sample.tabA2)
        host.sync()
        #expect(host.router.location == "workspace/\(sample.focus(sample.paneA, sample.tabA2))")
        #expect(host.router.history.entries.count == 2)

        host.layout = sample.selecting(sample.paneB, sample.tabB)
        host.sync()
        host.router.goBack()
        #expect(host.layout.focused == sample.paneA)
        #expect(host.layout.root.pane(sample.paneA)?.selected == sample.tabA2)
        host.router.goBack()
        #expect(host.layout.focused == sample.paneA)
        #expect(host.layout.root.pane(sample.paneA)?.selected == sample.tabA)
        #expect(!host.router.canGoBack)
        host.router.goForward()
        #expect(host.layout.root.pane(sample.paneA)?.selected == sample.tabA2)
        host.router.goForward()
        #expect(host.layout.focused == sample.paneB)
        #expect(host.layout.root.pane(sample.paneB)?.selected == sample.tabB)
    }

    @Test func aStalePaneTabLeavesTheWorkspaceWhereItIs() {
        let sample = WorkspaceFocusSample()
        let host = WorkspaceRouteHost(layout: sample.layout)
        host.sync()
        let before = host.layout
        host.router.navigate(to: "workspace/\(sample.focus(sample.paneA, UUID()))")
        host.sync()
        #expect(host.layout == before)
        #expect(host.router.location == "workspace/\(sample.focus(sample.paneA, sample.tabA))")
    }

    @Test func herdrSpaceSwitchesRestoreTheTabPaneAndSelectedTab() {
        let first = WorkspaceFocusSample()
        let second = WorkspaceFocusSample()
        let tabA = UUID()
        let tabB = UUID()
        let host = SpaceRouteHost(
            selected: tabA, layouts: [tabA: first.layout, tabB: second.layout])
        host.sync()
        #expect(
            host.router.location
                == WorkspaceFocusRoute.spaceValue(tabID: tabA, layout: first.layout))
        #expect(NavigationRoute(host.router.location)?.segments.count == 1)

        host.layouts[tabA] = first.selecting(first.paneA, first.tabA2)
        host.sync()
        host.selected = tabB
        host.sync()
        #expect(host.router.history.entries.count == 3)

        host.router.goBack()
        #expect(host.selected == tabA)
        #expect(host.layouts[tabA]?.focused == first.paneA)
        #expect(host.layouts[tabA]?.root.pane(first.paneA)?.selected == first.tabA2)
        host.router.goBack()
        #expect(host.layouts[tabA]?.root.pane(first.paneA)?.selected == first.tabA)
        host.router.goForward()
        host.router.goForward()
        #expect(host.selected == tabB)
        #expect(host.layouts[tabB]?.focused == second.paneA)
        #expect(host.layouts[tabB]?.root.pane(second.paneA)?.selected == second.tabA)
    }
}

private struct WorkspaceFocusSample {
    let layout: WorkspaceLayout
    let paneA: UUID
    let tabA: UUID
    let tabA2: UUID
    let paneB: UUID
    let tabB: UUID

    init() {
        let machine = UUID()
        var layout = WorkspaceLayout.single(machineID: machine, screen: .terminal)
        let pane = layout.root.panes[0]
        let first = pane.selected
        let extra = PaneTab(target: PaneTarget(machineID: machine, screen: .files))
        layout.root.updatePane(pane.id) { node in
            node.tabs.append(extra)
            node.selected = first
        }
        layout.split(
            paneID: pane.id, side: .right,
            target: PaneTarget(machineID: machine, screen: .docker))
        let other = layout.root.panes.first { $0.id != pane.id }!
        let otherTab = other.selected
        layout.focused = pane.id
        layout.root.updatePane(pane.id) { $0.selected = first }
        self.layout = layout
        paneA = pane.id
        tabA = first
        tabA2 = extra.id
        paneB = other.id
        tabB = otherTab
    }

    func focus(_ pane: UUID, _ tab: UUID) -> String {
        pane.uuidString + "~" + tab.uuidString
    }

    func selecting(_ pane: UUID, _ tab: UUID) -> WorkspaceLayout {
        var layout = layout
        precondition(WorkspaceFocusRoute.apply(focus(pane, tab), to: &layout))
        return layout
    }
}

@MainActor
private final class WorkspaceRouteHost {
    var place = "workspace"
    var layout: WorkspaceLayout
    let router = WindowRouter()

    init(layout: WorkspaceLayout) {
        self.layout = layout
    }

    func sync() {
        router.sync(
            depth: 0, name: "place", value: place,
            accept: { $0.isEmpty || $0 == "workspace" || $0 == "fleet" },
            apply: { self.place = $0 })
        router.sync(
            depth: 1, name: "focus", value: WorkspaceFocusRoute.value(layout),
            accept: { WorkspaceFocusRoute.accepts($0, layout: self.layout) },
            apply: { raw in
                var layout = self.layout
                guard WorkspaceFocusRoute.apply(raw, to: &layout) else { return }
                self.layout = layout
            })
    }
}

@MainActor
private final class SpaceRouteHost {
    var selected: UUID
    var layouts: [UUID: WorkspaceLayout]
    let router = WindowRouter()

    init(selected: UUID, layouts: [UUID: WorkspaceLayout]) {
        self.selected = selected
        self.layouts = layouts
    }

    func sync() {
        let value =
            layouts[selected].map {
                WorkspaceFocusRoute.spaceValue(tabID: selected, layout: $0)
            } ?? ""
        router.sync(
            depth: 0, name: "tab", value: value,
            accept: { raw in
                if raw.isEmpty { return true }
                guard let decoded = WorkspaceFocusRoute.decodeSpace(raw),
                    let layout = self.layouts[decoded.tabID]
                else { return false }
                return WorkspaceFocusRoute.accepts(decoded.focus, layout: layout)
            },
            apply: { raw in
                guard let decoded = WorkspaceFocusRoute.decodeSpace(raw),
                    var layout = self.layouts[decoded.tabID],
                    WorkspaceFocusRoute.apply(decoded.focus, to: &layout)
                else { return }
                self.layouts[decoded.tabID] = layout
                self.selected = decoded.tabID
            })
    }
}
