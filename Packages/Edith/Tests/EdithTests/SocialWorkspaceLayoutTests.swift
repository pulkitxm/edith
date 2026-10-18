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
        #expect(model.currentTab?.zoomed == nil)
    }
}
