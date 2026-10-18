import EdithKit
import Testing

@testable import Edith

@MainActor @Suite(.serialized)
struct SocialWorkspaceLayoutTests {
    @Test func everySessionLayoutAndAdjustmentRetainsAccountSessionsAndSavesCustomLayouts() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let accounts = Array(model.catalog.accounts.prefix(4))
        for account in accounts { model.open(account, beside: model.currentTab != nil) }
        let originalSessions = model.sessions
        let tab = try #require(model.currentTab)
        let templates = model.templates(for: 4)
        #expect(templates == HerdrLayoutTemplate.all(for: 4, saved: []))
        for template in templates {
            model.arrange(tab.id.uuidString, as: template)
            let layout = try #require(model.currentTab?.layout)
            #expect(
                layout.geometryMatches(
                    try #require(
                        template.layout(
                            [tab.focused] + tab.layout.panes.filter { $0 != tab.focused }))))
            #expect(Set(layout.panes) == Set(accounts.map { $0.id.uuidString }))
        }
        let before = try #require(model.currentTab?.layout)
        model.rotate(tab.id.uuidString)
        #expect(model.currentTab?.layout.geometryMatches(before.rotated()) == true)
        model.mirror(tab.id.uuidString, .horizontal)
        let saved = try #require(model.saveArrangement(of: tab.id.uuidString, named: "Review grid"))
        model.animatesLayout = true
        let restored = SocialManagerModel(file: fixture.file, defaults: fixture.defaults)
        restored.start()
        defer { restored.shutdown() }
        #expect(restored.animatesLayout)
        #expect(restored.templates(for: 4).contains(.saved(saved)))
        for (id, session) in originalSessions { #expect(model.sessions[id] === session) }
        model.equalize(tab.id.uuidString)
        model.toggleZoom(tab.focused)
        #expect(model.currentTab?.zoomed == tab.focused)
        model.separate(tab.id.uuidString)
        #expect(model.tabs.count == 4)
        model.gatherAll(into: try #require(model.currentTab?.id.uuidString))
        #expect(model.tabs.count == 1)
        #expect(model.currentTab?.layout.paneCount == 4)
        for (id, session) in originalSessions { #expect(model.sessions[id] === session) }
        restored.deleteArrangement(saved.id)
        #expect(!restored.templates(for: 4).contains(.saved(saved)))
    }

    @Test func sessionPaneShortcutsAreHandledWithWebContentFocused() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let accounts = Array(model.catalog.accounts.prefix(2))
        model.open(accounts[0])
        model.open(accounts[1], beside: true)
        #expect(
            WindowWorkspaceCommand.resolve(
                characters: nil, keyCode: 123, modifiers: [.command, .option])
                == .layout(.focus(.left)))
        #expect(
            WindowWorkspaceCommand.resolve(characters: nil, keyCode: 50, modifiers: .option)
                == .layout(.cycle(backwards: false)))
        #expect(
            WindowWorkspaceCommand.resolve(
                characters: nil, keyCode: 36, modifiers: [.command, .shift]) == .layout(.zoom))
        #expect(model.perform(.layout(.focus(.left))))
        #expect(model.currentTab?.focused == accounts[0].id.uuidString)
        #expect(model.perform(.layout(.zoom)))
        #expect(model.currentTab?.zoomed == accounts[0].id.uuidString)
        #expect(model.perform(.layout(.cycle(backwards: false))))
        #expect(model.currentTab?.focused == accounts[1].id.uuidString)
        #expect(model.currentTab?.zoomed == accounts[1].id.uuidString)
    }

    @Test func commandWClosesOnlyTheFocusedPaneAndReopenRestoresItsSplitPosition() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let accounts = Array(model.catalog.accounts.prefix(3))
        model.open(accounts[0])
        model.open(accounts[1], beside: true, side: .bottom)
        model.open(accounts[2], beside: true, side: .right)
        let original = try #require(model.currentTab)
        let survivor = try #require(model.sessions[accounts[1].id])
        model.focus(accounts[0].id.uuidString)
        #expect(model.perform(.closeTab))
        #expect(model.tabs.count == 1)
        #expect(model.currentTab?.id == original.id)
        #expect(model.currentTab?.layout.paneCount == 2)
        #expect(!model.paneIsOpen(accounts[0].id.uuidString))
        #expect(model.sessions[accounts[1].id] === survivor)
        #expect(model.perform(.reopenTab))
        #expect(model.currentTab?.id == original.id)
        #expect(model.currentTab?.layout.geometryMatches(original.layout) == true)
        #expect(model.currentTab?.focused == accounts[0].id.uuidString)
        #expect(model.sessions[accounts[1].id] === survivor)
        #expect(try fixture.file.load() == model.catalog)
    }

    @Test func closingWebsiteTabsDoesNotClosePanesAndLibraryCloseDoesNotCloseTheWindow() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let accounts = Array(model.catalog.accounts.prefix(2))
        model.open(accounts[0])
        model.open(accounts[1], beside: true)
        let session = try #require(model.sessions[accounts[1].id])
        let first = try #require(session.selectedPage)
        let popup = session.makePage()
        #expect(model.perform(.closeTab))
        #expect(session.pages.map(\.id) == [first.id])
        #expect(!session.pages.contains { $0.id == popup.id })
        #expect(model.currentTab?.layout.paneCount == 2)
        #expect(model.perform(.closeTab))
        #expect(model.currentTab?.layout.panes == [accounts[0].id.uuidString])
        #expect(model.perform(.showLibrary))
        let tabs = model.tabs
        #expect(model.perform(.closeTab))
        #expect(model.tabs == tabs)
    }

    @Test func numberShortcutsAndWrappingMatchAgentSessionsIncludingLibraryAndLastTab() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        for account in model.catalog.accounts { model.open(account) }
        let last = model.selectedTabID
        #expect(model.perform(.selectTab(0)))
        #expect(model.showingAccounts)
        #expect(model.perform(.selectTab(1)))
        #expect(model.selectedTabID == model.tabs.first?.id && !model.showingAccounts)
        #expect(model.perform(.previousTab))
        #expect(model.showingAccounts)
        #expect(model.perform(.previousTab))
        #expect(model.selectedTabID == last && !model.showingAccounts)
        #expect(model.perform(.selectTab(8)))
        #expect(model.selectedTabID == last)
        #expect(model.perform(.nextTab))
        #expect(model.showingAccounts)
    }

    @Test func savingAnExistingProfileKeepsLibraryScopeAndActiveBrowserSelection() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let profile = model.catalog.profiles[0]
        model.profileID = nil
        try model.saveProfile(id: profile.id, name: "Updated", badge: "U")
        #expect(model.profileID == nil && model.showingAccounts)
        model.profileID = model.catalog.profiles[1].id
        let scope = model.profileID
        let account = model.catalog.accounts[1]
        model.open(account)
        let tab = model.selectedTabID
        let browser = try #require(model.sessions[account.id])
        try model.saveProfile(id: profile.id, name: "Renamed", badge: "R")
        #expect(model.profileID == scope && !model.showingAccounts)
        #expect(model.selectedTabID == tab)
        #expect(model.sessions[account.id] === browser)
        #expect(model.catalog.accounts == (try fixture.file.load()).accounts)
    }
}
