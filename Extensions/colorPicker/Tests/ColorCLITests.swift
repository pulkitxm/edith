import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import ColorPickerExtension

@MainActor @Suite(.serialized) struct ColorCLITests {
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
