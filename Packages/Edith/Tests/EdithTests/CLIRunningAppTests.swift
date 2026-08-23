import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIRunningAppTests {
    static let finder = RunningAppSnapshot(
        pid: 1, name: "Finder", bundleID: "com.apple.finder", active: false)
    static let safari = RunningAppSnapshot(
        pid: 42, name: "Safari", bundleID: "com.apple.Safari", active: true)
    static let music = RunningAppSnapshot(
        pid: 84, name: "Music", bundleID: "com.apple.Music", active: false)

    @Test func listUsesStableSharedSnapshotsInPlainAndJSON() async throws {
        let json = await CLIProbe.runInWorld(["apps", "ls", "--json"]) { _ in
            CLIEnvironment.runningApps = { [Self.safari, Self.music] }
        }
        let plain = await CLIProbe.runInWorld(["apps", "ls"]) { _ in
            CLIEnvironment.runningApps = { [Self.safari, Self.music] }
        }

        #expect(json.code == 0)
        let rows = try #require(json.array as? [[String: Any]])
        #expect(rows.map { $0["name"] as? String } == ["Music", "Safari"])
        #expect(
            Set(rows[0].keys)
                == ["active", "bundleID", "cpuPercent", "memoryMB", "name", "pid"])
        #expect(plain.stdout.contains("Music"))
        #expect(plain.stdout.contains("Safari"))
        #expect(plain.stdout.contains("CPU"))
        #expect(plain.stdout.contains("MEMORY"))
    }

    @Test func namedPreviewNeedsNoHelperAndPostsNothing() async throws {
        final class Capture: @unchecked Sendable {
            var posted: [Notification.Name] = []
        }
        let capture = Capture()
        let result = await CLIProbe.runInWorld(
            ["apps", "quit", "Safari", "--json"]
        ) { _ in
            CLIEnvironment.runningApps = { [Self.safari] }
            CLIEnvironment.deliver = { name, _ in capture.posted.append(name) }
        }

        #expect(result.code == 0)
        let object = try #require(result.object)
        #expect(object["operation"] as? String == "apps.quit")
        #expect(object["applied"] as? Bool == false)
        #expect(object["changed"] as? Int == 0)
        #expect(capture.posted.isEmpty)
    }

    @Test func confirmedQuitSendsOnlyThePlannedPID() async throws {
        final class Capture: @unchecked Sendable {
            var posted: [(name: Notification.Name, info: [String: Any])] = []
        }
        let capture = Capture()
        let result = await CLIProbe.runInWorld(
            ["apps", "quit", "Safari", "--force", "--yes", "--json"]
        ) { world in
            CLIEnvironment.runningApps = { [Self.safari, Self.music] }
            world.helperRunning(true)
            CLIEnvironment.deliver = { name, info in
                capture.posted.append((name, info ?? [:]))
            }
            CLIEnvironment.answer = { name in
                guard name == IPC.Name.quitAppsResult,
                    let requestID = capture.posted.last?.info[RunningAppIPC.requestIDKey] as? String
                else { return nil }
                return [
                    RunningAppIPC.requestIDKey: requestID,
                    RunningAppIPC.changedKey: 1,
                ]
            }
        }

        #expect(result.code == 0)
        let object = try #require(result.object)
        #expect(object["applied"] as? Bool == true)
        #expect(object["acknowledged"] as? Bool == true)
        #expect(object["requested"] as? Int == 1)
        #expect(object["changed"] as? Int == 1)
        #expect(capture.posted.count == 1)
        #expect(capture.posted[0].name == IPC.Name.requestQuitApps)
        #expect(capture.posted[0].info[RunningAppIPC.pidsKey] as? [Int] == [42])
        #expect(capture.posted[0].info[RunningAppIPC.forceKey] as? Bool == true)
        #expect(capture.posted[0].info[RunningAppIPC.requestIDKey] as? String != nil)
    }

    @Test func allPreviewListsExactUnprotectedTargets() async throws {
        let result = await CLIProbe.runInWorld(
            ["apps", "quit", "--all", "--json"]
        ) { _ in
            CLIEnvironment.runningApps = { [Self.safari, Self.finder, Self.music] }
        }

        #expect(result.code == 0)
        let object = try #require(result.object)
        let targets = try #require(object["targets"] as? [[String: Any]])
        #expect(targets.map { $0["name"] as? String } == ["Music", "Safari"])
        #expect(object["applied"] as? Bool == false)
        #expect(object["acknowledged"] as? Bool == false)
        #expect(object["changed"] as? Int == 0)
    }

    @Test func emptyAllPreviewHasCleanPlainOutput() async {
        let result = await CLIProbe.runInWorld(["apps", "quit", "--all"]) { _ in
            CLIEnvironment.runningApps = { [Self.finder] }
        }

        #expect(result.code == 0)
        #expect(result.stdout == "would quit 0 apps; pass --yes to apply\n")
    }

    @Test func plainPreviewNamesTheTargetAndConfirmationFlag() async {
        let result = await CLIProbe.runInWorld(["apps", "quit", "Safari"]) { _ in
            CLIEnvironment.runningApps = { [Self.safari] }
        }

        #expect(result.code == 0)
        #expect(result.stdout == "would quit Safari; pass --yes to apply\n")
        #expect(result.stderr.isEmpty)
    }

    @Test func protectedTargetsFailBeforeAnyRequest() async {
        let result = await CLIProbe.runInWorld(
            ["apps", "quit", "Finder", "--yes", "--json"]
        ) { world in
            CLIEnvironment.runningApps = { [Self.finder] }
            world.helperRunning(true)
        }

        #expect(result.code == 1)
        #expect(result.stderr.contains("Finder is protected"))
    }

    @Test func confirmedQuitFailsWhenTheHelperDoesNotAcknowledge() async {
        let result = await CLIProbe.runInWorld(
            ["apps", "quit", "Safari", "--yes", "--json"]
        ) { world in
            CLIEnvironment.runningApps = { [Self.safari] }
            world.helperRunning(true)
            CLIEnvironment.answer = { _ in nil }
        }

        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("did not answer for quitting apps"))
    }

    @Test func confirmedPlainOutputReportsTheAcknowledgedCount() async {
        final class Capture: @unchecked Sendable {
            var requestID: String?
        }
        let capture = Capture()
        let result = await CLIProbe.runInWorld(
            ["apps", "quit", "--all", "--yes"]
        ) { world in
            CLIEnvironment.runningApps = { [Self.safari, Self.music] }
            world.helperRunning(true)
            CLIEnvironment.deliver = { _, info in
                capture.requestID = info?[RunningAppIPC.requestIDKey] as? String
            }
            CLIEnvironment.answer = { name in
                guard name == IPC.Name.quitAppsResult, let requestID = capture.requestID else {
                    return nil
                }
                return [
                    RunningAppIPC.requestIDKey: requestID,
                    RunningAppIPC.changedKey: 1,
                ]
            }
        }

        #expect(result.code == 0)
        #expect(result.stdout == "Edith accepted quit for 1 of 2 apps\n")
        #expect(result.stderr.isEmpty)
    }

    @Test func anUnrelatedQuitReplyIsNotAnAcknowledgement() async {
        let result = await CLIProbe.runInWorld(
            ["apps", "quit", "Safari", "--yes", "--json"]
        ) { world in
            CLIEnvironment.runningApps = { [Self.safari] }
            world.helperRunning(true)
            CLIEnvironment.answer = { _ in
                [
                    RunningAppIPC.requestIDKey: "another-request",
                    RunningAppIPC.changedKey: 1,
                ]
            }
        }

        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("did not answer for quitting apps"))
    }

    @Test func runningAppCompletionUsesNamesAndBundleIDs() {
        let result = CompletionEngine.plan(
            CompletionRequest(words: ["ed", "apps", "quit", "com.apple."], index: 3),
            machines: [], configKeys: [], extensionIDs: [],
            runningApps: ["Safari", "com.apple.Safari", "Music", "com.apple.Music"])

        #expect(result.candidates == ["com.apple.Safari", "com.apple.Music"])
    }
}

@Suite struct CLIRunningAppProcessTests {
    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-running-app-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func listAndPreviewWorkOutsideARepository() throws {
        let outside = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }

        let list = try CLIProcessProbe.run(
            ["apps", "ls", "--json"], currentDirectory: outside)
        let preview = try CLIProcessProbe.run(
            ["apps", "quit", "--all", "--json"], currentDirectory: outside)

        #expect(list.code == 0)
        #expect(list.array != nil)
        #expect(list.stderr.isEmpty)
        #expect(preview.code == 0)
        #expect(preview.object?["operation"] as? String == "apps.quit")
        #expect(preview.object?["applied"] as? Bool == false)
        #expect(preview.object?["changed"] as? Int == 0)
        #expect(preview.stderr.isEmpty)
    }
}
