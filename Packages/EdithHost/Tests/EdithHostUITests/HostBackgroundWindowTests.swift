import AppKit
import SwiftUI
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized) struct HostBackgroundWindowTests {
    @Test(arguments: [false, true])
    func nativeCloseRetiresOnlyTheExactOwnedWindowAndReopeningConstructsANewOwner(
        performClose: Bool
    ) throws {
        var constructed: [NSWindow] = []
        var presented: [NSWindow] = []
        let sections = HostSectionWindows(
            saveFrames: false,
            makeWindow: {
                let window = TestWindowHost.window(
                    contentRect: $0, styleMask: [.titled, .closable, .resizable])
                constructed.append(window)
                return window
            },
            present: { presented.append($0) }
        ) { AnyView(Text("Synthetic " + $0.title)) }
        defer { sections.closeAll() }
        let home = try #require(sections.open("home"))
        let settings = try #require(sections.open("settings"))
        #expect(home.delegate === sections)
        #expect(settings.delegate === sections)
        #expect(!home.isVisible && !settings.isVisible)
        #expect(sections.openDestinations == ["settings", "home"])
        if performClose { home.performClose(nil) } else { home.close() }
        #expect(sections.openDestinations == ["settings"])
        #expect(!sections.contains(home))
        #expect(sections.contains(settings))
        #expect(!sections.focusExisting("home"))
        let replacement = try #require(sections.open("home"))
        #expect(replacement !== home)
        #expect(replacement.delegate === sections)
        #expect(constructed.count == 3)
        #expect(presented.last === replacement)
        let foreign = TestWindowHost.window(contentRect: .zero)
        defer { foreign.close() }
        sections.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: foreign))
        sections.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: home))
        #expect(sections.contains(replacement))
        #expect(sections.openDestinations == ["home", "settings"])
        sections.closeAll()
        #expect(sections.openDestinations.isEmpty)
        #expect(!sections.contains(settings) && !sections.contains(replacement))
        #expect(constructed.allSatisfy { !$0.isVisible })
    }
}
