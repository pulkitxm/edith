import Foundation
import Testing

@testable import EdithCore

@Suite struct GitHubBrowserSessionTests {
    @Test func roundTripsVersionedStateAndPresentation() throws {
        var regular = tab(1, "acme/orbit")
        regular.updateCurrentPresentation(
            scrollOffset: 128.5, horizontalScrollOffset: 32.25,
            lineSelection: .range(12...18), wrapsLines: true,
            find: GitHubBrowserFindState(query: "actor", selectedMatch: 2, isCaseSensitive: true))
        regular.updateAddressBarDraft("acme/orbit/tree/main")
        let pinned = tab(2, "acme/orbit/issues", pinned: true)
        let session = GitHubBrowserSession(
            tabs: [regular, pinned], selectedTabID: regular.id)

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(GitHubBrowserSession.self, from: data)

        #expect(String(decoding: data, as: UTF8.self).contains("\"version\":1"))
        #expect(decoded == session)
        #expect(decoded.tabs.map(\.id) == [pinned.id, regular.id])
        #expect(decoded.selectedTab?.currentEntry.scrollOffset == 128.5)
        #expect(decoded.selectedTab?.currentEntry.horizontalScrollOffset == 32.25)
        #expect(decoded.selectedTab?.currentEntry.lineSelection == .range(12...18))
        #expect(decoded.selectedTab?.currentEntry.wrapsLines == true)
        #expect(decoded.selectedTab?.currentEntry.find?.query == "actor")
        #expect(decoded.selectedTab?.addressBarDraft == "acme/orbit/tree/main")
    }

    @Test func duplicatesAndReordersInsidePinnedPartition() {
        let regularA = tab(1, "acme/a")
        let pinnedA = tab(2, "acme/pinned-a", pinned: true)
        let regularB = tab(3, "acme/b")
        let pinnedB = tab(4, "acme/pinned-b", pinned: true)
        let duplicateID = id(5)
        let openedID = id(6)
        var session = GitHubBrowserSession(
            tabs: [regularA, pinnedA, regularB, pinnedB], selectedTabID: regularA.id)

        #expect(session.tabs.map(\.id) == [pinnedA.id, pinnedB.id, regularA.id, regularB.id])
        let duplicated = session.duplicateTab(regularA.id, as: duplicateID)
        #expect(duplicated == duplicateID)
        #expect(
            session.tabs.map(\.id)
                == [pinnedA.id, pinnedB.id, regularA.id, duplicateID, regularB.id])
        #expect(session.selectedTabID == duplicateID)
        #expect(session.tab(id: duplicateID)?.historyEntries == regularA.historyEntries)
        #expect(
            session.openTab(entry: entry("acme/new"), id: openedID, select: false) == openedID)
        #expect(session.tabs.last?.id == openedID)
        #expect(session.selectedTabID == duplicateID)

        session.reorderTab(regularB.id, to: 0)
        session.reorderTab(pinnedB.id, to: 0)
        #expect(
            session.tabs.map(\.id)
                == [pinnedB.id, pinnedA.id, regularB.id, regularA.id, duplicateID, openedID])
        session.setPinned(true, tabID: regularA.id)
        session.setPinned(false, tabID: pinnedA.id)
        #expect(session.tabs.map(\.isPinned) == [true, true, false, false, false, false])
        #expect(
            session.tabs.map(\.id) == [
                pinnedB.id, regularA.id, pinnedA.id, regularB.id, duplicateID, openedID,
            ])
    }

    @Test func closesReopensAndBoundsRecentlyClosedTabs() {
        let pinned = tab(1, "acme/pinned", pinned: true)
        let regularA = tab(2, "acme/a")
        let regularB = tab(3, "acme/b")
        var session = GitHubBrowserSession(
            tabs: [pinned, regularA, regularB], selectedTabID: regularA.id)

        let closed = session.closeTab(regularA.id)
        #expect(closed?.id == regularA.id)
        #expect(session.tabs.map(\.id) == [pinned.id, regularB.id])
        #expect(session.selectedTabID == regularB.id)
        let reopened = session.reopenLastClosedTab()
        #expect(reopened == regularA.id)
        #expect(session.tabs.map(\.id) == [pinned.id, regularA.id, regularB.id])
        #expect(session.selectedTabID == regularA.id)

        let many = (10..<22).map { tab($0, "acme/\($0)") }
        var bounded = GitHubBrowserSession(tabs: many, selectedTabID: many[0].id)
        for item in many { bounded.closeTab(item.id) }
        #expect(bounded.recentlyClosed.count == GitHubBrowserSession.recentlyClosedLimit)
        #expect(bounded.recentlyClosed.map(\.tab.id) == Array(many.reversed().prefix(10)).map(\.id))
    }

    @Test func navigatesReloadsAndPrunesTheForwardBranch() {
        let tabID = id(1)
        let first = entry("acme/orbit")
        let second = entry("acme/orbit/issues")
        let abandoned = entry("acme/orbit/pulls")
        let branch = entry("acme/orbit/branches")
        var session = GitHubBrowserSession(
            tabs: [GitHubBrowserTab(id: tabID, entry: first)], selectedTabID: tabID)

        #expect(session.tab(id: tabID)?.addressBarDraft == first.route.url.absoluteString)
        let drafted = session.updateAddressBarDraft(tabID: tabID, text: "acme/orbit/issues/12")
        let openedSecond = session.navigate(tabID: tabID, to: second)
        let openedAbandoned = session.navigate(tabID: tabID, to: abandoned)
        let firstBack = session.goBack(tabID: tabID)
        let draftAfterBack = session.tab(id: tabID)?.addressBarDraft
        let secondBack = session.goBack(tabID: tabID)
        let forward = session.goForward(tabID: tabID)
        let draftAfterForward = session.tab(id: tabID)?.addressBarDraft
        let openedBranch = session.navigate(tabID: tabID, to: branch)
        #expect(
            drafted && openedSecond && openedAbandoned && firstBack && secondBack && forward
                && openedBranch)
        #expect(draftAfterBack == second.route.url.absoluteString)
        #expect(draftAfterForward == second.route.url.absoluteString)
        #expect(session.tab(id: tabID)?.addressBarDraft == branch.route.url.absoluteString)
        #expect(session.tab(id: tabID)?.historyEntries == [first, second, branch])
        #expect(session.tab(id: tabID)?.canGoForward == false)

        let revision = session.tab(id: tabID)?.reloadRevision
        let reloaded = session.reload(tabID: tabID)
        #expect(reloaded == branch)
        #expect(session.tab(id: tabID)?.reloadRevision == revision.map { $0 + 1 })
        let updated = session.updateCurrentPresentation(
            tabID: tabID, scrollOffset: 44, horizontalScrollOffset: 7,
            lineSelection: .single(9), wrapsLines: true,
            find: GitHubBrowserFindState(query: "session", selectedMatch: 1))
        #expect(updated)
        #expect(session.tab(id: tabID)?.currentEntry.scrollOffset == 44)
        #expect(session.tab(id: tabID)?.currentEntry.horizontalScrollOffset == 7)
        #expect(session.tab(id: tabID)?.currentEntry.lineSelection == .single(9))
        #expect(session.tab(id: tabID)?.currentEntry.wrapsLines == true)
        #expect(session.tab(id: tabID)?.currentEntry.find?.selectedMatch == 1)
    }

    private func tab(
        _ value: Int, _ path: String, pinned: Bool = false
    ) -> GitHubBrowserTab {
        GitHubBrowserTab(id: id(value), entry: entry(path), isPinned: pinned)
    }

    private func entry(_ path: String) -> GitHubBrowserHistoryEntry {
        GitHubBrowserHistoryEntry(
            route: GitHubRoute(url: URL(string: "https://github.com/\(path)")!)!)
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
