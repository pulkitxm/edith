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

    @Test func toolVersionsAreRememberedUntilTheBinaryChanges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-toolcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = ToolVersionCache.storeURL
        ToolVersionCache.storeURL = dir.appendingPathComponent("versions.json")
        defer { ToolVersionCache.storeURL = previous }

        let binary = dir.appendingPathComponent("fake-tool")
        try "one".write(to: binary, atomically: true, encoding: .utf8)
        #expect(ToolVersionCache.cached(for: binary) == nil)
        ToolVersionCache.remember("1.0.0", for: binary)
        #expect(ToolVersionCache.cached(for: binary) == "1.0.0")

        try "a longer body that changes the size".write(
            to: binary, atomically: true, encoding: .utf8)
        #expect(ToolVersionCache.cached(for: binary) == nil)
    }

    @Test func aToolThatIsNotThereHasNoRememberedVersion() {
        let missing = URL(fileURLWithPath: "/nope/not/a/tool")
        #expect(ToolVersionCache.stamp(for: missing) == nil)
        #expect(ToolVersionCache.cached(for: missing) == nil)
    }

    @Test func theCLIAndTheUIAgreeOnHowAPlaySourceIsSpelled() {
        #expect(
            MusicSourceRequest.folder("Albums/Live").payload as? [String: String]
                == ["sourceKind": "folder", "sourcePath": "Albums/Live"])
        #expect(
            MusicSourceRequest.favourites.payload as? [String: String]
                == ["sourceKind": "favourites"])
        for request: MusicSourceRequest in [
            .folder("a/b"), .directory("c"), .favourites, .all,
        ] {
            #expect(MusicSourceRequest.decode(request.payload) == request)
        }
        #expect(MusicSourceRequest.decode(["kind": "folder", "path": "a"]) == nil)
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
