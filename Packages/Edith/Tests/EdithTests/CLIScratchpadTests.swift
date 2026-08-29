import AppKit
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIScratchpadTests {
    @Test func namedPadWorkflowProducesJSONAndChangeSignals() async {
        await CLIProbe.inWorld { world in
            let created = await CLIProbe.capture([
                "scratchpad", "create", "--name", "Release", "--text", "# Checklist", "--json",
            ])
            #expect(created.code == 0)
            #expect(created.object?["name"] as? String == "Release")
            #expect(created.object?["text"] as? String == "# Checklist")

            let renamed = await CLIProbe.capture([
                "scratchpad", "rename", "Release", "Launch", "--json",
            ])
            #expect(renamed.code == 0)
            #expect(renamed.object?["name"] as? String == "Launch")

            let duplicated = await CLIProbe.capture([
                "scratchpad", "duplicate", "Launch", "--json",
            ])
            #expect(duplicated.code == 0)
            #expect(duplicated.object?["name"] as? String == "Launch copy")

            let list = await CLIProbe.capture([
                "scratchpad", "ls", "--search", "checklist", "--json",
            ])
            #expect(list.code == 0)
            #expect(list.array?.count == 2)
            #expect((list.array?.first as? [String: Any])?["matches"] as? Int == 1)
            #expect(
                world.postedNames()
                    == Array(repeating: IPC.Name.scratchpadChanged.rawValue, count: 3))
        }
    }

    @Test func copyExportClearAndRemoveKeepExactContent() async throws {
        try await CLIProbe.inWorld { world in
            _ = await CLIProbe.capture([
                "scratchpad", "create", "--name", "Exact", "--text", "line 1\n**line 2**", "--json",
            ])

            let copied = await CLIProbe.capture(["scratchpad", "copy-all", "Exact", "--json"])
            #expect(copied.code == 0)
            #expect(world.pasteboard.string(forType: .string) == "line 1\n**line 2**")

            let destination = world.sandbox.appendingPathComponent("exact.md")
            let exported = await CLIProbe.capture([
                "scratchpad", "export", "Exact", destination.path, "--json",
            ])
            #expect(exported.code == 0)
            let content = try String(contentsOf: destination, encoding: .utf8)
            #expect(content == "line 1\n**line 2**")

            let preview = await CLIProbe.capture(["scratchpad", "clear", "Exact", "--json"])
            #expect(preview.code == 0)
            #expect(preview.object?["applied"] as? Bool == false)

            let cleared = await CLIProbe.capture([
                "scratchpad", "clear", "Exact", "--yes", "--json",
            ])
            #expect(cleared.code == 0)
            #expect(cleared.object?["applied"] as? Bool == true)

            let removed = await CLIProbe.capture([
                "scratchpad", "rm", "Exact", "--yes", "--json",
            ])
            #expect(removed.code == 0)
            #expect(removed.object?["remaining"] as? Int == 1)
        }
    }

    @Test func openRequiresEnabledExtensionAndHelper() async {
        await CLIProbe.inWorld { world in
            var result = await CLIProbe.capture(["scratchpad", "open", "--json"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("extension is off"))

            world.shared.set(true, forKey: AppStorageKeys.Scratchpad.enabled)
            world.helperRunning(true)
            result = await CLIProbe.capture(["scratchpad", "open", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["requested"] as? Bool == true)
            #expect(world.postedNames() == [IPC.Name.requestScratchpadPanel.rawValue])
        }
    }

    @Test func rememberIsDeliberateAndCompanionOptional() async {
        await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture(["scratchpad", "remember", "--json"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("Scratchpad works without Companion"))
        }
    }
}
