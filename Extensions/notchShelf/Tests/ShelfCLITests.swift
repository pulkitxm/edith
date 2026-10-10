import EdithExtensionSupport
import Foundation
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct ShelfCLITests {
    @Test func originalCommandsMutateOwnedFilesAndPreservePreviewAndOutput() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let source = fixture.directory.appendingPathComponent("mock-report.txt")
        try Data("synthetic report".utf8).write(to: source)
        let added = try await fixture.run(["add", source.path, "--json"])
        #expect(added.exitCode == 0)
        #expect(added.stderr.isEmpty)
        let row = try #require(
            try JSONSerialization.jsonObject(with: Data(added.stdout.utf8)) as? [String: Any])
        #expect(row["name"] as? String == "mock-report.txt")
        #expect(row["index"] as? Int == 1)
        let path = try #require(row["path"] as? String)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("synthetic report".utf8))
        let listed = try await fixture.run(["ls"])
        #expect(listed.stdout.contains("NAME"))
        #expect(listed.stdout.contains("mock-report.txt"))
        let updated = try await fixture.run(["update", "1", "--x", "72", "--y", "91", "--json"])
        #expect(updated.exitCode == 0)
        #expect(
            try ShelfMutationExecution.snapshot(root: fixture.root).items.first?.position
                == CGPoint(x: 72, y: 91))
        let preview = try await fixture.run(["rm", "1", "--json"])
        #expect(preview.stdout.contains("\"applied\": false"))
        #expect(FileManager.default.fileExists(atPath: path))
        let removed = try await fixture.run(["rm", "1", "--yes", "--json"])
        #expect(removed.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try Data(contentsOf: source) == Data("synthetic report".utf8))
        let empty = try await fixture.run(["ls"])
        #expect(empty.stdout.isEmpty)
        #expect(empty.stderr == "the shelf is empty\n")
    }

    @Test func textPathClearAndPurgeRetainOriginalSemantics() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        #expect(try await fixture.run(["add-text", "synthetic", "note"]).exitCode == 0)
        let path = try await fixture.run(["path", "1"])
        #expect(
            try String(
                contentsOfFile: path.stdout.trimmingCharacters(in: .newlines), encoding: .utf8)
                == "synthetic note")
        let preview = try await fixture.run(["clear"])
        #expect(preview.stderr == "nothing changed; pass --yes to apply this plan\n")
        #expect(try ShelfMutationExecution.snapshot(root: fixture.root).items.count == 1)
        fixture.defaults.set("oneHour", forKey: AppStorageKeys.Notch.shelfKeepDuration)
        _ = try ShelfMutationExecution.addText(
            "expired fixture", root: fixture.root, addedAt: Date().addingTimeInterval(-7200),
            sender: "fixture")
        let purged = try await fixture.run(["purge", "--yes", "--json"])
        #expect(purged.exitCode == 0)
        #expect(try ShelfMutationExecution.snapshot(root: fixture.root).items.count == 1)
        #expect(try await fixture.run(["clear", "--yes"]).exitCode == 0)
        #expect(try ShelfMutationExecution.snapshot(root: fixture.root).items.isEmpty)
    }

    @Test func usageFailuresAndNativeShareSelectionHaveExactChannels() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let missing = try await fixture.run(["path", "0"])
        #expect(missing.exitCode == 4)
        #expect(missing.stdout.isEmpty)
        #expect(missing.stderr.hasPrefix("error: the shelf is empty\n"))
        let invalid = try await fixture.run(["add-text"])
        #expect(invalid.exitCode == 2)
        #expect(invalid.stderr == "error: text is required\n")
        _ = try await fixture.run(["add-text", "mock note"])
        let items = try ShelfMutationExecution.snapshot(root: fixture.root).items
        var received: [UUID] = []
        let reply = try await ShelfCLIExecution.run(
            .init(arguments: ["share", "1", "1", "--json"]), root: fixture.root,
            defaults: fixture.defaults
        ) { received = $0 }
        #expect(received == [items[0].id])
        #expect(reply.exitCode == 0)
        #expect(reply.stdout.contains("\"opened\": true"))
        await #expect(throws: CancellationError.self) {
            _ = try await ShelfCLIExecution.run(
                .init(arguments: ["share", "1"]), root: fixture.root, defaults: fixture.defaults
            ) { _ in throw CancellationError() }
        }
        #expect(try await fixture.run(["ls", "--json"]).exitCode == 0)
    }

    @Test func openAndRevealUsePinnedOwnedSelectionsAndPreserveNativeFailures() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try await fixture.run(["add-text", "native action fixture"])
        var opened: [URL] = []
        var openedContent: String?
        let open = try await ShelfCLIExecution.run(
            .init(arguments: ["open", "1", "--json"]), root: fixture.root,
            defaults: fixture.defaults,
            open: { url in
                opened.append(url)
                openedContent = try? String(contentsOf: url, encoding: .utf8)
                return true
            }
        ) { _ in Issue.record("Open must not share") }
        #expect(open.exitCode == 0)
        #expect(open.stderr.isEmpty)
        #expect(opened.count == 1)
        #expect(open.stdout.contains("\"opened\": true"))
        #expect(openedContent == "native action fixture")
        var revealed: [URL] = []
        let reveal = try await ShelfCLIExecution.run(
            .init(arguments: ["reveal", "1", "--json"]), root: fixture.root,
            defaults: fixture.defaults,
            reveal: { revealed = $0 }
        ) { _ in Issue.record("Reveal must not share") }
        #expect(reveal.exitCode == 0)
        #expect(revealed.map(\.lastPathComponent) == opened.map(\.lastPathComponent))
        #expect(reveal.stdout.contains("\"requested\": true"))
        let failure = try await ShelfCLIExecution.run(
            .init(arguments: ["open", "1"]), root: fixture.root, defaults: fixture.defaults,
            open: { _ in false }
        ) { _ in Issue.record("Open must not share") }
        #expect(failure.exitCode == 4)
        #expect(failure.stdout.isEmpty)
        #expect(failure.stderr == "error: macOS could not open the shelf items\n")
        #expect(try ShelfMutationExecution.snapshot(root: fixture.root).items.count == 1)
    }

    @MainActor private struct Fixture {
        let id = "shelf-cli-fixture-" + UUID().uuidString
        let directory: URL
        let root: URL
        let defaults: UserDefaults
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
            root = directory.appendingPathComponent("Shelf")
            defaults = try #require(UserDefaults(suiteName: id))
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        func run(_ arguments: [String]) async throws -> ExtensionCLIReply {
            try await ShelfCLIExecution.run(
                .init(arguments: arguments), root: root, defaults: defaults
            ) { _ in throw ExtensionPeerError.unavailable }
        }
        func clean() {
            UserDefaults.standard.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
