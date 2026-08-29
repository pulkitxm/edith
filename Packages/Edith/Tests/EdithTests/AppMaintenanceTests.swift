import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

private final class AppMaintenanceRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CLICommandRequest?

    func record(_ request: CLICommandRequest) {
        lock.withLock { stored = request }
    }

    func request() -> CLICommandRequest? {
        lock.withLock { stored }
    }
}

@Suite struct AppMaintenanceTests {
    @Test func inventoryFindsRegularAppsAndAppliesExactHomebrewUpdates() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let app = try makeApp(
            at: applications.appendingPathComponent("Example App.app"),
            bundleID: "com.example.app", version: "1.0")
        let update = try #require(
            """
            {"casks":[{"name":"example-app","installed_versions":["1.0"],"current_version":"2.0"}]}
            """.data(using: .utf8))

        let found = AppMaintenanceInventory.applications(
            roots: [applications], home: root, updateData: update)

        #expect(found.count == 1)
        #expect(found[0].url == app)
        #expect(found[0].update?.latestVersion == "2.0")
        #expect(found[0].update?.source == "Homebrew")

        let current = AppMaintenanceInventory.applyingHomebrewUpdates(
            Data(
                """
                {"casks":[{"name":"example-app","installed_versions":["1.0"],"current_version":"1.0"}]}
                """.utf8),
            to: found.map {
                InstalledApplication(
                    id: $0.id, name: $0.name, bundleID: $0.bundleID, version: "1.0", url: $0.url)
            })
        #expect(current[0].update == nil)
    }

    @Test func updateInventoryRunsABoundedHomebrewProbe() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        _ = try makeApp(
            at: applications.appendingPathComponent("Example App.app"),
            bundleID: "com.example.app", version: "1.0")
        let capture = AppMaintenanceRequestCapture()

        let found = await AppMaintenanceInventory.applicationsWithUpdates(
            roots: [applications], home: root, homebrewPaths: ["/usr/bin/true"]
        ) { request in
            capture.record(request)
            return CLICommandResult(
                terminationStatus: 0,
                output:
                    """
                    {"casks":[{"name":"example-app","installed_versions":["1.0"],"current_version":"2.0"}]}
                    """)
        }

        let request = try #require(capture.request())
        #expect(request.executableURL.path == "/usr/bin/true")
        #expect(request.arguments == ["outdated", "--cask", "--greedy", "--json=v2"])
        #expect(request.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(request.timeout == 60)
        #expect(request.maximumOutputBytes == 2 * 1_024 * 1_024)
        #expect(request.terminatesProcessGroup)
        #expect(found.first?.update?.latestVersion == "2.0")
    }

    @Test func scanIncludesOnlyExactBundleIdentifierPaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let app = try makeApp(
            at: applications.appendingPathComponent("Example.app"),
            bundleID: "com.example.app", version: "1.0")
        let caches = root.appendingPathComponent("Library/Caches/com.example.app")
        let unrelated = root.appendingPathComponent("Library/Caches/Example")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: caches.appendingPathComponent("entry"))

        let plan = try AppMaintenanceExecution.plan(
            applicationURL: app, applicationRoots: [applications], home: root)

        #expect(plan.items.map(\.url.path).contains(app.path))
        #expect(plan.items.map(\.url.path).contains(caches.path))
        #expect(!plan.items.map(\.url.path).contains(unrelated.path))
    }

    @Test func removalUsesOnlyReviewedItemsAndRejectsChangedPaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let app = try makeApp(
            at: applications.appendingPathComponent("Example.app"),
            bundleID: "com.example.app", version: "1.0")
        let cache = root.appendingPathComponent("Library/Caches/com.example.app")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var plan = try AppMaintenanceExecution.plan(
            applicationURL: app, applicationRoots: [applications], home: root)
        let cacheItem = try #require(plan.items.first { $0.url.path == cache.path })
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var moved: [URL] = []

        let result = try AppMaintenanceExecution.remove(
            plan: plan, selectedIDs: [cacheItem.id], trash: { moved.append($0) })

        #expect(moved.isEmpty)
        #expect(result.removed.isEmpty)
        #expect(result.failed.map(\.id) == [cacheItem.id])

        plan = try AppMaintenanceExecution.plan(
            applicationURL: app, applicationRoots: [applications], home: root)
        let originalInfo = app.appendingPathComponent("Contents/Info.plist")
        let replacementInfo = app.appendingPathComponent("Contents/Info.replacement.plist")
        try Data("changed".utf8).write(to: replacementInfo)
        try FileManager.default.removeItem(at: originalInfo)
        try FileManager.default.moveItem(at: replacementInfo, to: originalInfo)
        #expect(throws: AppMaintenanceError.applicationChanged) {
            try AppMaintenanceExecution.remove(
                plan: plan, selectedIDs: [app.path], trash: { moved.append($0) })
        }
        try makeInfoPlist(at: originalInfo, bundleID: "com.example.app", version: "1.0")
        plan = try AppMaintenanceExecution.plan(
            applicationURL: app, applicationRoots: [applications], home: root)
        let appItem = try #require(plan.items.first { $0.category == .application })
        let safe = try AppMaintenanceExecution.remove(
            plan: plan, selectedIDs: [appItem.id], trash: { moved.append($0) })
        #expect(safe.removed.map(\.id) == [appItem.id])
        #expect(moved == [app])
    }

    @Test func protectedAndSymlinkedApplicationsAreRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let protected = try makeApp(
            at: applications.appendingPathComponent("Apple.app"),
            bundleID: "com.apple.example", version: "1")
        #expect(throws: AppMaintenanceError.protectedApplication) {
            try AppMaintenanceExecution.plan(
                applicationURL: protected, applicationRoots: [applications], home: root)
        }
        let target = try makeApp(
            at: root.appendingPathComponent("Target.app"), bundleID: "com.example.target",
            version: "1")
        let link = applications.appendingPathComponent("Target.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: AppMaintenanceError.invalidApplication) {
            try AppMaintenanceExecution.plan(
                applicationURL: link, applicationRoots: [applications], home: root)
        }
    }

    @Test func commandTreeAndParserExposeMaintenanceFlow() throws {
        let node = try #require(CommandTree.root.child("maintenance"))
        #expect(
            node.children.map(\.name)
                == ["inventory", "scan", "remove", "install", "updates", "update", "history"])
        #expect(
            try EdRoot.parseAsRoot(["maintenance", "inventory", "--no-updates"])
                is MaintenanceInventoryCommand)
        #expect(
            try EdRoot.parseAsRoot(["maintenance", "remove", "/Applications/Test.app"])
                is MaintenanceRemoveCommand)
        #expect(
            try EdRoot.parseAsRoot(["maintenance", "install", "/tmp/Test.dmg"])
                is MaintenanceInstallCommand)
        #expect(
            try EdRoot.parseAsRoot(["maintenance", "updates", "--json"])
                is MaintenanceUpdatesCommand)
        #expect(
            try EdRoot.parseAsRoot(["maintenance", "update", "brew:sample"])
                is MaintenanceUpdateCommand)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeApp(at url: URL, bundleID: String, version: String) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try makeInfoPlist(
            at: contents.appendingPathComponent("Info.plist"), bundleID: bundleID,
            version: version)
        return url.standardizedFileURL
    }

    private func makeInfoPlist(at url: URL, bundleID: String, version: String) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": url.deletingLastPathComponent().deletingLastPathComponent()
                .deletingPathExtension().lastPathComponent,
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }
}
