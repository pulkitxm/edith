import AppKit
import EdithKit
import ImageIO
import Testing
import WebKit

@testable import Edith

@MainActor @Suite(.serialized)
struct SocialWorkspaceControlsTests {
    @Test func emailIsProfileScopedAndMovesBetweenTabsAndSplitsWithoutReplacingItsSession() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let studio = try model.saveProfile(
            id: model.catalog.profiles[0].id, name: "Studio", badge: "ST",
            email: "studio@example.test")
        let personal = model.catalog.profiles[1]
        let social = model.accounts(in: studio)[0]
        model.open(social)
        model.openEmail(studio, beside: true)
        let email = try #require(model.account(studio.id.uuidString))
        let browser = try #require(model.sessions[email.id])
        #expect(model.platform(for: email)?.website.absoluteString == "https://mail.google.com")
        #expect(model.currentTab?.layout.panes == [social.id.uuidString, email.id.uuidString])
        model.openEmail(studio)
        #expect(model.tabs.count == 2)
        #expect(model.currentTab?.layout.paneCount == 1)
        #expect(model.sessions[email.id] === browser)
        model.openEmail(personal)
        #expect(model.sessions[personal.id] !== browser)
        #expect(model.sessions[personal.id]?.dataStore !== browser.dataStore)
        try model.saveProfile(
            id: studio.id, name: "Studio", badge: "ST", email: "updated@example.test")
        #expect(model.account(studio.id.uuidString)?.name == "updated@example.test")
        #expect(model.sessions[email.id] === browser)
        #expect(try fixture.file.load() == model.catalog)
    }

    @Test func reorderingMovingAndRestoringLayoutsKeepAccountIdentityAndBrowsers() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let accounts = model.catalog.accounts
        for account in accounts.prefix(3) { model.open(account) }
        let ids = model.tabs.map(\.id)
        model.reorderTab(ids[2], before: ids[0])
        #expect(model.tabs.map(\.id) == [ids[2], ids[0], ids[1]])
        model.shiftTab(ids[2], by: 1)
        #expect(model.tabs.map(\.id) == [ids[0], ids[2], ids[1]])
        let browser = try #require(model.sessions[accounts[1].id])
        model.moveToTab(accounts[1], tabID: ids[0])
        model.moveToTab(accounts[0], tabID: ids[0], near: accounts[1].id.uuidString, side: .bottom)
        #expect(
            model.currentTab?.layout.panes == [
                accounts[1].id.uuidString, accounts[0].id.uuidString,
            ])
        #expect(model.sessions[accounts[1].id] === browser)
        let target = model.catalog.profiles[0]
        model.moveAccount(accounts[1], to: target)
        #expect(model.account(accounts[1].id.uuidString)?.profileID == target.id)
        #expect(model.sessions[accounts[1].id] === browser)
        let saved = try #require(model.currentTab)
        model.closeTab(saved.id)
        model.reopenClosedTab()
        #expect(model.currentTab?.layout == saved.layout)
        #expect(model.currentTab?.focused == saved.focused)
        #expect(Set(model.tabs.flatMap(\.layout.panes)).count == 3)
        model.closeOtherTabs(try #require(model.selectedTabID))
        #expect(model.tabs.count == 1)
        #expect(model.sessions.count == 2)
    }

    @Test func keyboardCommandsAreWindowScopedWithAWebViewAsFirstResponder() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.open(model.catalog.accounts[0])
        let first = try #require(model.selectedTabID)
        model.open(model.catalog.accounts[1])
        let second = try #require(model.selectedTabID)
        let window = TestWindowHost.window(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600))
        defer { window.orderOut(nil) }
        let webView = try #require(
            model.sessions[model.catalog.accounts[1].id]?.selectedPage?.webView)
        window.contentView = webView
        window.makeFirstResponder(webView)
        let router = WindowRouter()
        router.attach(window, role: .main)
        defer { router.detach() }
        let owner = UUID()
        router.registerWorkspaceCommands(owner: owner) { model.perform($0) }
        let command = try #require(
            WindowWorkspaceCommand.resolve(
                characters: "\t", keyCode: 48, modifiers: [.control, .shift]))
        #expect(WindowRouter.router(for: window)?.performWorkspaceCommand(command) == true)
        #expect(model.selectedTabID == first)
        #expect(router.performWorkspaceCommand(.nextTab))
        #expect(model.selectedTabID == second)
        #expect(router.performWorkspaceCommand(.nextTab))
        #expect(model.showingAccounts)
        #expect(router.performWorkspaceCommand(.previousTab))
        #expect(!model.showingAccounts && model.selectedTabID == second)
        router.unregisterWorkspaceCommands(owner: UUID())
        #expect(router.performWorkspaceCommand(.focusAddress))
        router.unregisterWorkspaceCommands(owner: owner)
        #expect(!router.performWorkspaceCommand(.nextTab))
        #expect(
            WindowWorkspaceCommand.resolve(
                characters: "\t", keyCode: 48, modifiers: [.control, .option]) == nil)
    }

    @Test func picturesAreDownsampledPersistedPreservedOnRenameAndDeletedWithTheirAccount()
        async throws
    {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let account = model.catalog.accounts[0]
        let source = fixture.folder.appendingPathComponent("mock-avatar.png")
        let image = NSImage(size: NSSize(width: 600, height: 400), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: source)
        try model.importAvatar(account, from: source)
        let filename = try #require(model.account(account.id.uuidString)?.avatarFilename)
        let data = try model.avatarFiles.read(filename)
        let thumbnail = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(thumbnail, 0, nil))
        #expect(pixels.width == 256)
        #expect(pixels.height <= 256)
        #expect(model.avatars[account.id] != nil)
        let updated = try model.saveAccount(
            id: account.id, profileID: account.profileID, platformID: account.platformID,
            name: "New name", badge: "N")
        #expect(updated.avatarFilename == filename)
        #expect(try fixture.file.load().accounts.first?.avatarFilename == filename)
        #expect(throws: CocoaError.self) { try model.avatarFiles.read("../mock-avatar.png") }
        await model.clearSession(updated, removingAccount: true)
        #expect(model.avatars[account.id] == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: model.avatarFiles.directory.appendingPathComponent(filename).path))
    }
}
