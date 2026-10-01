import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct LiveCancelCLITests {
    @Test func commandsParse() throws {
        #expect(try EdRoot.parseAsRoot(["brew", "cancel"]) is HomebrewCancelCommand)
        #expect(try EdRoot.parseAsRoot(["companion", "stop"]) is CompanionStopCommand)
        #expect(
            try EdRoot.parseAsRoot(["attention", "extension", "install"])
                is AttentionExtensionInstallCommand)
        #expect(
            try EdRoot.parseAsRoot(["attention", "extension", "reveal"])
                is AttentionExtensionInstallCommand)
        #expect(
            try EdRoot.parseAsRoot(["attention", "extension", "open"])
                is AttentionExtensionOpenCommand)
        #expect(
            try EdRoot.parseAsRoot(["attention", "extension", "token"])
                is AttentionExtensionTokenCommand)
    }

    @Test func cancelJSONReportsTheWindowAndTheCommand() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-flights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let previousDirectory = CLIFlights.directoryOverride
        let previousAlive = CLIFlights.alive
        let previousSignal = CLIFlights.signal
        CLIFlights.directoryOverride = folder
        CLIFlights.alive = { $0 == 4242 }
        CLIFlights.signal = { $0 == 4242 }
        defer {
            CLIFlights.directoryOverride = previousDirectory
            CLIFlights.alive = previousAlive
            CLIFlights.signal = previousSignal
        }
        _ = CLIFlights.begin(
            kind: "brew", action: "install", target: "formula ripgrep", pid: 4242, onlyCLI: false)
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { name in
                guard name == IPC.Name.homebrewCancelResult else { return nil }
                let requestID =
                    world.postedPayloads(for: IPC.Name.requestHomebrewCancel).last?["requestID"]
                    as? String ?? ""
                return ["ok": true, "requestID": requestID, "cancelled": "true"]
            }
            let result = await CLIProbe.capture(["brew", "cancel", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["action"] as? String == "cancel")
            #expect(result.object?["window"] as? Int == 1)
            let commands = result.object?["commands"] as? [[String: Any]]
            #expect(commands?.first?["target"] as? String == "formula ripgrep")
            #expect(commands?.first?["pid"] as? Int == 4242)
        }
    }

    @Test func stopWithNothingRunningSaysSo() async {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { name in
                guard name == IPC.Name.companionStopResult else { return nil }
                let requestID =
                    world.postedPayloads(for: IPC.Name.requestCompanionStop).last?["requestID"]
                    as? String ?? ""
                return ["ok": true, "requestID": requestID, "stopped": "0"]
            }
            let result = await CLIProbe.capture(["companion", "stop"])
            #expect(result.code == 0)
            #expect(result.stdout.contains("no companion reply is being written"))
        }
    }

    @Test func extensionInstallRevealsTheFolderItWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-extension-\(UUID().uuidString)/chrome-extension", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let revealed = FlightBox()
        let previousReveal = AttentionExtensionInstaller.revealDirectory
        let previousDirectory = AttentionExtensionInstaller.installedDirectoryOverride
        AttentionExtensionInstaller.revealDirectory = { revealed.add($0.path) }
        AttentionExtensionInstaller.installedDirectoryOverride = folder
        defer {
            AttentionExtensionInstaller.revealDirectory = previousReveal
            AttentionExtensionInstaller.installedDirectoryOverride = previousDirectory
        }
        let result = await CLIProbe.run(["attention", "extension", "install", "--json"])
        #expect(result.code == 0)
        let path = try #require(result.object?["path"] as? String)
        #expect(result.object?["action"] as? String == "install")
        #expect(path.hasSuffix("chrome-extension"))
        #expect(revealed.values == [path])
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func extensionOpenUsesTheSharedPage() async {
        let opened = FlightBox()
        let previous = AttentionExtensionInstaller.openURL
        AttentionExtensionInstaller.openURL = { url in
            opened.add(url.absoluteString)
            return true
        }
        defer { AttentionExtensionInstaller.openURL = previous }
        let result = await CLIProbe.run(["attention", "extension", "open", "--json"])
        #expect(result.code == 0)
        #expect(result.object?["opened"] as? Bool == true)
        #expect(opened.values == ["chrome://extensions"])
    }

    @Test func tokenReadsTheSavedSettingsAndCanCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-attention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = AttentionSettings()
        settings.serverToken = "synthetic-token"
        try AttentionRepository(root: root).saveSettings(settings)
        let copied = FlightBox()
        let previousRepository = AttentionExtensionCLI.repository
        let previousCopy = AttentionExtensionCLI.copyToken
        AttentionExtensionCLI.repository = { AttentionRepository(root: root) }
        AttentionExtensionCLI.copyToken = { copied.add($0) }
        defer {
            AttentionExtensionCLI.repository = previousRepository
            AttentionExtensionCLI.copyToken = previousCopy
        }
        let result = await CLIProbe.run(["attention", "extension", "token", "--copy", "--json"])
        #expect(result.code == 0)
        #expect(result.object?["token"] as? String == "synthetic-token")
        #expect(copied.values == ["synthetic-token"])
    }
}

private final class FlightBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func add(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
