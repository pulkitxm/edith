import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import ColorPickerExtension

@MainActor @Suite(.serialized) struct ColorCLITests {

    @Test func discoveryCatalogContainsOnlyOriginalParserRoutesAndRejectsForeignPayloads()
        throws
    {
        let data = try ColorCLIExecution.catalog(Data("{}".utf8))
        let catalog = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["version"] as? Int == 1)
        #expect(catalog["owner"] as? String == "colorPicker")
        #expect(catalog["acceptsInput"] as? Bool == false)
        let commands = try #require(catalog["commands"] as? [[String: Any]])
        let routes = commands.compactMap { $0["route"] as? [String] }
        var expected: [[String]] = [
            ["color"], ["color", "pick"], ["color", "ls"], ["color", "copy"], ["color", "clear"],
        ]
        expected.append(["color", "help"])
        #expect(Set(routes) == Set(expected))
        #expect(routes.count == Set(routes).count)
        #expect(commands.allSatisfy { $0["operation"] as? String == "colorPicker.cli" })
        let documents = try #require(catalog["parserHelp"] as? [[String: Any]])
        #expect(documents.count == 1)
        #expect(documents[0]["serializationVersion"] as? Int == 0)
        let help = try #require(documents[0]["command"] as? [String: Any])
        #expect(help["commandName"] as? String == "color")

        #expect(throws: (any Error).self) {
            try ColorCLIExecution.catalog(Data("{\"arguments\":[]}".utf8))
        }
    }

    @Test func originalActionReceivesTheExactCallerContextAndDoesNotLeakIt() async throws {
        let request = try ExtensionCLIRequest(
            arguments: ["pick"], standardInput: Data("synthetic terminal input".utf8),
            workingDirectory: "/tmp/synthetic-terminal-context", interactive: true)
        var observed: ExtensionCLIRequest?
        let defaults = UserDefaults(suiteName: "edith.color.context." + UUID().uuidString)!
        defaults.set(true, forKey: AppStorageKeys.ColorPicker.enabled)
        let reply = try await ColorCLIExecution.run(
            request, defaults: defaults, pick: { observed = ExtensionCLIContext.request },
            write: { _ in false }, changed: {})
        #expect(reply.exitCode == 0)
        #expect(observed == request)
        #expect(ExtensionCLIContext.request == nil)
    }
    @Test func originalListCopyPickAndClearPreserveOwnedHistory() async throws {
        let defaults = UserDefaults(suiteName: "edith.color.cli." + UUID().uuidString)!
        defaults.set(true, forKey: AppStorageKeys.ColorPicker.enabled)
        let swatch = ColorSwatch(red: 1, green: 0, blue: 0, profile: .sRGB)
        ColorHistoryStore.add(swatch, limit: 100, into: defaults)
        var picked = 0
        var writes: [String] = []
        var changes = 0
        func run(_ arguments: [String]) async throws -> ExtensionCLIReply {
            try await ColorCLIExecution.run(
                ExtensionCLIRequest(arguments: arguments), defaults: defaults,
                pick: { picked += 1 },
                write: {
                    writes.append($0); return true
                }, changed: { changes += 1 })
        }
        let list = try await run(["ls", "--format", "hex"])
        #expect(list.stdout == swatch.string(for: .hex) + "\n")
        let copy = try await run(["copy", "1", "--format", "rgb"])
        #expect(copy.stdout == "copied colour 1 as \(swatch.string(for: .rgb))\n")
        #expect(writes == [swatch.string(for: .rgb)])
        let pick = try await run(["pick", "--json"])
        #expect(pick.exitCode == 0 && picked == 1)
        let preview = try await run(["clear", "--json"])
        let plan = try #require(
            JSONSerialization.jsonObject(with: Data(preview.stdout.utf8)) as? [String: Any])
        #expect(plan["applied"] as? Bool == false)
        #expect(ColorHistoryStore.load(from: defaults).count == 1)
        #expect(changes == 0)
        let clear = try await run(["clear", "--yes"])
        #expect(clear.stdout == "cleared 1 colours\n")
        #expect(ColorHistoryStore.load(from: defaults).isEmpty)
        #expect(changes == 1)
        let empty = try await run(["copy", "1"])
        #expect(empty.exitCode == 4 && empty.stdout.isEmpty)
        let invalid = try await run(["ls", "--limit", "-1"])
        #expect(invalid.exitCode == 2)
        defaults.set(false, forKey: AppStorageKeys.ColorPicker.enabled)
        let disabled = try await run(["pick"])
        #expect(disabled.exitCode == 4 && picked == 1)
    }

    @Test func pasteboardFailureIsReportedWithoutClaimingCopy() async throws {
        let defaults = UserDefaults(suiteName: "edith.color.cli." + UUID().uuidString)!
        ColorHistoryStore.add(
            ColorSwatch(red: 0, green: 1, blue: 0, profile: .sRGB), limit: 1, into: defaults)
        let reply = try await ColorCLIExecution.run(
            ExtensionCLIRequest(arguments: ["copy", "1"]),
            defaults: defaults, pick: {}, write: { _ in false }, changed: {})
        #expect(reply.exitCode == 4)
        #expect(reply.stdout.isEmpty)
        #expect(reply.stderr.contains("pasteboard refused"))
    }
}
