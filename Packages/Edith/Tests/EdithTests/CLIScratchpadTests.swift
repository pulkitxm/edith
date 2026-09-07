import AppKit
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIScratchpadTests {
    @Test func mutationsRequireTheAgentWithoutWritingFromTheCLI() async {
        await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture([
                "scratchpad", "create", "--name", "Release", "--text", "Checklist", "--json",
            ])
            #expect(result.code != 0)
            #expect(!FileManager.default.fileExists(atPath: ScratchpadPaths.documentFile.path))
        }
    }

    @Test func openRequiresEnabledExtensionAndHelper() async {
        await CLIProbe.inWorld { world in
            var result = await CLIProbe.capture(["scratchpad", "open", "--json"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("extension is off"))

            world.shared.set(true, forKey: "suiteDeskEnabled")
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
