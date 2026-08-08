import EdithKit
import Foundation
import Testing

@testable import EdithCLI

@Suite struct CLIInProcessWorkTests {
    @Test func toolsInstallDoesTheInstallItselfRatherThanAskingTheApp() async throws {
        try await CLIProbe.inWorld { world in
            world.helperRunning(false)
            CLIEnvironment.executableNamed = { _ in nil }
            CLIEnvironment.installTool = { _, log in
                log("Downloading yt-dlp")
                return "2026.07.04"
            }
            let result = await CLIProbe.capture(["tools", "install", "yt-dlp", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["installed"] as? Bool == true)
            #expect(result.object?["version"] as? String == "2026.07.04")
            #expect(world.postedNames().isEmpty)
        }
    }

    @Test func toolsInstallReportsTheManualInstructionWhenItFails() async throws {
        try await CLIProbe.inWorld { _ in
            CLIEnvironment.executableNamed = { _ in nil }
            CLIEnvironment.installTool = { _, _ in
                throw ToolInstallFailure.noPackageManager("Claude Code")
            }
            let result = await CLIProbe.capture(["tools", "install", "claude"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("Neither Homebrew nor npm"))
            #expect(result.stderr.contains("brew install"))
            #expect(result.stdout.isEmpty)
        }
    }

    @Test func downloadCancelSaysWhenNothingStoppedTheRunningTransfer() async throws {
        try await CLIProbe.inWorld { _ in
            CLIEnvironment.isMainAppRunning = { false }
            let result = await CLIProbe.capture(["download", "cancel", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["appRunning"] as? Bool == false)
            #expect(result.object?["stoppedRunning"] as? Bool == false)
        }
    }

    @Test func limitsRefreshThatGoesUnansweredIsAnErrorRatherThanStaleNumbers() async throws {
        try await CLIProbe.inWorld { world in
            world.helperRunning(true)
            world.answers { _ in nil }
            let result = await CLIProbe.capture(["usage", "limits", "--refresh"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stdout.isEmpty)
        }
    }
}
