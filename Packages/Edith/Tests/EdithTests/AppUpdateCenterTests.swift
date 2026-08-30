import Foundation
import Testing

@testable import EdithKit

private final class UpdateExecutionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var attempts: [String: Int] = [:]

    func begin(_ name: String) -> Int {
        lock.withLock {
            active += 1
            peak = max(peak, active)
            attempts[name, default: 0] += 1
            return attempts[name]!
        }
    }

    func end() { lock.withLock { active -= 1 } }
    var maximumActive: Int { lock.withLock { peak } }
}

@Suite struct AppUpdateCenterTests {
    @Test func comparesNumericVersionsConservatively() {
        #expect(AppUpdateDiscovery.isNewer("2.10", than: "2.9"))
        #expect(!AppUpdateDiscovery.isNewer("1.2.0", than: "1.2"))
        #expect(!AppUpdateDiscovery.isNewer("latest", than: "99"))
    }

    @Test func parsesCasksAndFormulaeIntoOneInventory() throws {
        let app = InstalledApplication(
            id: "/Applications/Example App.app", name: "Example App",
            bundleID: "com.example.app", version: "1.0",
            url: URL(fileURLWithPath: "/Applications/Example App.app"))
        let data = try #require(
            """
            {
              "casks": [{"name":"example-app","installed_versions":["1.0"],"current_version":"2.0"}],
              "formulae": [{"name":"sample","installed_versions":["3.0"],"current_version":"3.2"}]
            }
            """.data(using: .utf8))
        let items = AppUpdateDiscovery.parseHomebrew(
            data, applications: [app], executable: "/opt/homebrew/bin/brew",
            now: Date(timeIntervalSince1970: 10))

        #expect(items.count == 2)
        #expect(items.map(\.source) == [.homebrewCask, .homebrewFormula])
        #expect(items[0].bundleID == "com.example.app")
        #expect(items[1].command == "/opt/homebrew/bin/brew upgrade sample")
    }

    @Test func parsesStoreUpdatesWithExactApplicationMatch() {
        let app = InstalledApplication(
            id: "/Applications/Pages.app", name: "Pages", bundleID: "com.apple.Pages",
            version: "14.0", url: URL(fileURLWithPath: "/Applications/Pages.app"))
        let items = AppUpdateDiscovery.parseMAS(
            "409201541 Pages (14.0 -> 15.1)\n",
            applications: [app], executable: "/opt/homebrew/bin/mas",
            now: Date(timeIntervalSince1970: 20))

        #expect(items.count == 1)
        #expect(items[0].availableVersion == "15.1")
        #expect(items[0].arguments == ["upgrade", "409201541"])
    }

    @Test func discoversHTTPSFeedAndReleaseInformation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Example.app")
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.feed", "CFBundleName": "Example",
            "CFBundleShortVersionString": "1.0", "SUFeedURL": "https://example.com/appcast.xml",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        let application = InstalledApplication(
            id: appURL.path, name: "Example", bundleID: "com.example.feed", version: "1.0",
            url: appURL)
        let feed = Data(
            """
            <rss xmlns:sparkle="https://sparkle-project.org/xml-namespaces/sparkle"><channel><item><title>Example 2</title><description>Faster and safer</description><link>https://example.com/releases/2</link><enclosure sparkle:shortVersionString="2.0" /></item></channel></rss>
            """.utf8)

        let items = await AppUpdateDiscovery.feedUpdates(
            applications: [application], now: Date(timeIntervalSince1970: 30),
            fetch: { _ in feed })

        #expect(items.count == 1)
        #expect(items[0].source == .sparkle)
        #expect(items[0].releaseTitle == "Example 2")
        #expect(items[0].releaseNotes == "Faster and safer")
        #expect(items[0].releaseURL?.absoluteString == "https://example.com/releases/2")
    }

    @Test func formatsEscapedHTMLReleaseNotes() throws {
        let feed = try #require(
            """
            <rss xmlns:sparkle="https://sparkle-project.org/xml-namespaces/sparkle"><channel><item><title>Example 2</title><description>&lt;p&gt;Faster and safer.&lt;/p&gt;&lt;ul&gt;&lt;li&gt;Improved reliability&lt;/li&gt;&lt;li&gt;Keep &amp;quot;On&amp;quot;&lt;/li&gt;&lt;li&gt;App&amp;#39;s updater&lt;/li&gt;&lt;/ul&gt;</description><enclosure sparkle:shortVersionString="2.0" /></item></channel></rss>
            """.data(using: .utf8))

        let release = try #require(AppUpdateDiscovery.parseFeed(feed))

        #expect(
            release.notes
                == """
                Faster and safer.
                • Improved reliability
                • Keep "On"
                • App's updater
                """)
    }

    @Test func persistenceAppliesIgnoreSnoozeExclusionHistoryAndBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("state.json")
        let backup = root.appendingPathComponent("backup.json")
        let persistence = AppUpdatePersistence(fileURL: file)
        let item = updateItem(id: "brew:example", bundleID: "com.example", version: "2")
        var state = AppUpdateCenterState(
            ignoredVersions: [item.id: "2"], snoozedUntil: [:],
            excludedBundleIDs: [], history: [], lastRefresh: Date(timeIntervalSince1970: 40))

        try persistence.save(state)
        #expect(persistence.load() == state)
        #expect(persistence.visible([item], state: state, now: Date()).isEmpty)
        state.ignoredVersions = [:]
        state.snoozedUntil[item.id] = Date().addingTimeInterval(3_600)
        #expect(persistence.visible([item], state: state, now: Date()).isEmpty)
        state.snoozedUntil = [:]
        state.excludedBundleIDs.insert("com.example")
        #expect(persistence.visible([item], state: state, now: Date()).isEmpty)
        try persistence.backup(to: backup)
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func executorRequiresConfirmationBoundsConcurrencyAndRetries() async throws {
        let executor = AppUpdateExecutor()
        let items = (1...5).map {
            updateItem(id: "brew:\($0)", bundleID: "com.example.\($0)", version: "2")
        }
        let plan = AppUpdatePlan(items: items, concurrency: 2, retries: 1)
        await #expect(throws: AppUpdateCenterError.confirmationRequired) {
            try await executor.execute(plan, confirmed: false)
        }
        let probe = UpdateExecutionProbe()
        let results = try await executor.execute(plan, confirmed: true) { request in
            let attempt = probe.begin(request.arguments.last ?? "")
            defer { probe.end() }
            try await Task.sleep(for: .milliseconds(20))
            return CLICommandResult(terminationStatus: attempt == 1 ? 1 : 0, output: "")
        }

        #expect(probe.maximumActive == 2)
        #expect(results.count == 5)
        #expect(results.allSatisfy { $0.status == .succeeded && $0.attempts == 2 })
    }

    private func updateItem(id: String, bundleID: String, version: String) -> AppUpdateItem {
        AppUpdateItem(
            id: id, name: id, bundleID: bundleID, source: .homebrewCask,
            currentVersion: "1", availableVersion: version, confidence: .high,
            checkedAt: Date(timeIntervalSince1970: 1), action: .install,
            executablePath: "/opt/homebrew/bin/brew", arguments: ["upgrade", id])
    }
}
