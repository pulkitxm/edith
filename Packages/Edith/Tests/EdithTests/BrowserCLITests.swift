import Foundation
import Testing

@testable import EdithCLI
@testable import EdithHelper
@testable import EdithKit

@Suite struct BrowserCLITests {
    @Test func requestsRoundTripThroughJSON() throws {
        let request = NotchBrowserRequest.navigate("https://example.com", tab: "2")
        let encoded = try #require(request.encoded)
        #expect(NotchBrowserRequest.decode(encoded) == request)
        let snapshot = NotchBrowserSnapshot(
            attached: true, profile: NotchBrowserProfileState(id: "Default", name: "Work"),
            profiles: [NotchBrowserProfileState(id: "Default", name: "Work")],
            tabs: [
                NotchBrowserTabState(
                    id: "tab", index: 1, title: "Example", url: "https://example.com",
                    selected: true, loading: false)
            ],
            sync: "idle", canReopen: false, link: "https://example.com")
        #expect(NotchBrowserSnapshot.decode(snapshot.encoded) == snapshot)
        let tab = try BrowserCLI.tab("1", in: snapshot)
        #expect(tab.title == "Example")
        #expect(throws: CLIFailure.self) { try BrowserCLI.tab("9", in: snapshot) }
    }

    @MainActor @Test func statusWithoutChromeStaysDetached() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installation = ChromeInstallation(
            applicationURL: { nil }, defaultBrowser: { nil },
            userData: ChromeUserData(root: directory))
        let store = NotchBrowserStore(
            installation: installation,
            sessionFile: BrowserSessionFile(url: directory.appendingPathComponent("session.json")))
        let snapshot = try store.perform(.status)
        #expect(!snapshot.attached)
        #expect(snapshot.tabs.isEmpty)
        #expect(throws: NotchBrowserActionError.self) {
            try store.perform(.navigate("https://example.com", tab: nil))
        }
    }
}
