import AppKit
import ArgumentParser
import Foundation

@testable import EdithCLI
@testable import EdithKit

actor CLIGate {
    static let shared = CLIGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
    }

    func release() {
        busy = false
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}

struct CLIRun: Sendable {
    var stdout: String
    var stderr: String
    var code: Int32

    var stdoutLines: [String] {
        stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.isEmpty }
    }

    func decoded() throws -> Any {
        try JSONSerialization.jsonObject(
            with: Data(stdout.utf8), options: [.fragmentsAllowed])
    }

    var object: [String: Any]? { (try? decoded()) as? [String: Any] }
    var array: [Any]? { (try? decoded()) as? [Any] }
}

enum CLIProcessProbe {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static var binary: URL {
        packageRoot.appendingPathComponent(".build/debug/ed")
    }

    static func run(
        _ arguments: [String], executable: URL? = nil, currentDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CLIRun {
        let process = Process()
        process.executableURL = executable ?? binary
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CLIRun(
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self), code: process.terminationStatus)
    }
}

final class CLIWorld: @unchecked Sendable {
    let suite: String
    let shared: UserDefaults
    let standard: UserDefaults
    let sandbox: URL
    let pasteboard: NSPasteboard
    private(set) var posted: [(name: Notification.Name, info: [String: Any])] = []
    private(set) var scripts: [String] = []
    private(set) var openedURLs: [URL] = []
    private let lock = NSLock()

    init(_ label: String = UUID().uuidString) {
        suite = "test.cli.\(label)"
        pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        pasteboard.clearContents()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-cli-world-\(label)")
        try? FileManager.default.createDirectory(
            at: sandbox, withIntermediateDirectories: true)
        ClipboardPaths.root = sandbox
        AttentionPaths.root = sandbox
        MachinePaths.root = sandbox
        ShelfIndex.root = sandbox.appendingPathComponent("Shelf")
        CLIEnvironment.homeDirectory = sandbox
        CLIEnvironment.clipboardPasteboard = pasteboard
        shared = UserDefaults(suiteName: suite)!
        standard = UserDefaults(suiteName: suite + ".standard")!
        shared.removePersistentDomain(forName: suite)
        standard.removePersistentDomain(forName: suite + ".standard")
        CLIEnvironment.sharedDefaults = shared
        CLIEnvironment.standardDefaults = standard
        CLIEnvironment.isHelperRunning = { false }
        CLIEnvironment.isMainAppRunning = { false }
        CLIEnvironment.executableNamed = { _ in nil }
        CLIEnvironment.resolveCompanionEndpoint = {
            CompanionClient.endpoint(override: $0 ?? "http://127.0.0.1:1")
        }
        CLIEnvironment.answer = { _ in nil }
        CLIEnvironment.permissionUsages = { [] }
        CLIEnvironment.runningApps = { [] }
        CLIEnvironment.usageRefresh = .scripted(events: [])
        CLIEnvironment.installTool = { tool, _ in
            throw ToolInstallFailure.unverified(tool.displayName)
        }
        CLIEnvironment.openURL = { [weak self] url in
            self?.note(url: url)
            return true
        }
        CLIEnvironment.deliver = { [weak self] name, info in
            self?.record(name, info ?? [:])
        }
        CLIEnvironment.runAppleScript = { [weak self] source, _ in
            self?.note(script: source)
            throw CLIFailure.unavailable("no player in tests")
        }
    }

    private func record(_ name: Notification.Name, _ info: [String: Any]) {
        lock.lock()
        posted.append((name, info))
        lock.unlock()
    }

    private func note(script: String) {
        lock.lock()
        scripts.append(script)
        lock.unlock()
    }

    private func note(url: URL) {
        lock.lock()
        openedURLs.append(url)
        lock.unlock()
    }

    func postedNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return posted.map(\.name.rawValue)
    }

    func postedPayloads(for name: Notification.Name) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return posted.filter { $0.name == name }.map(\.info)
    }

    func recordedScripts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return scripts
    }

    func recordedURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return openedURLs
    }

    func helperRunning(_ running: Bool) {
        CLIEnvironment.isHelperRunning = { running }
    }

    func answers(_ block: @escaping @Sendable (Notification.Name) -> [AnyHashable: Any]?) {
        CLIEnvironment.answer = block
    }

    func players(_ snapshots: [MusicPlayer: PlayerSnapshot]) {
        CLIEnvironment.runAppleScript = { [weak self] source, _ in
            self?.note(script: source)
            for (player, snapshot) in snapshots {
                guard let name = player.processName, source.contains("\"\(name)\"") else {
                    continue
                }
                guard source.contains("player state") else { return "ok" }
                guard snapshot.isRunning else { return PlayerScript.notRunningMarker }
                let separator = PlayerScript.separator
                return [
                    "ok", snapshot.isPlaying ? "playing" : "paused", snapshot.title,
                    snapshot.artist, String(snapshot.elapsedSeconds),
                    String(snapshot.durationSeconds),
                    String(Int((snapshot.volume ?? 0) * 100)),
                ].joined(separator: separator)
            }
            return PlayerScript.notRunningMarker
        }
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: sandbox)
        shared.removePersistentDomain(forName: suite)
        standard.removePersistentDomain(forName: suite + ".standard")
        pasteboard.clearContents()
        CLIEnvironment.reset()
        AttentionPaths.root = AppData.supportDir
    }
}

final class RunBox: @unchecked Sendable {
    var value = CLIRun(stdout: "", stderr: "", code: -1)
}

enum CLIProbe {
    static func inWorld(
        _ body: (CLIWorld) async throws -> Void
    ) async rethrows {
        await CLIGate.shared.acquire()
        let world = CLIWorld()
        do {
            try await body(world)
        } catch {
            world.tearDown()
            await CLIGate.shared.release()
            throw error
        }
        world.tearDown()
        await CLIGate.shared.release()
    }

    static func exclusive(_ body: () async throws -> Void) async rethrows {
        await CLIGate.shared.acquire()
        do {
            try await body()
        } catch {
            await CLIGate.shared.release()
            throw error
        }
        await CLIGate.shared.release()
    }

    static func run(_ arguments: [String]) async -> CLIRun {
        let box = RunBox()
        await inWorld { _ in box.value = await capture(arguments) }
        return box.value
    }

    static func runInWorld(_ arguments: [String], _ setUp: (CLIWorld) -> Void) async -> CLIRun {
        let box = RunBox()
        await inWorld { world in
            setUp(world)
            box.value = await capture(arguments)
        }
        return box.value
    }

    static func capture(_ arguments: [String]) async -> CLIRun {
        await capturing {
            var command = try EdRoot.parseAsRoot(arguments)
            if var runnable = command as? AsyncParsableCommand {
                try await runnable.run()
            } else {
                try command.run()
            }
        }
    }

    static func isolate(_ body: () async throws -> Void) async -> CLIRun {
        let box = RunBox()
        await inWorld { _ in box.value = await capturing(body) }
        return box.value
    }

    static func capturing(_ body: () async throws -> Void) async -> CLIRun {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-cli-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let outURL = directory.appendingPathComponent("stdout")
        let errURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
            let errHandle = try? FileHandle(forWritingTo: errURL)
        else {
            return CLIRun(stdout: "", stderr: "could not open capture files", code: -1)
        }
        let savedOut = CLIOut.stdoutHandle
        let savedErr = CLIOut.stderrHandle
        CLIOut.stdoutHandle = outHandle
        CLIOut.stderrHandle = errHandle
        var code: Int32 = 0
        do {
            try await body()
        } catch {
            ExitCodes.report(error)
            code = ExitCodes.code(for: error)
        }
        CLIOut.stdoutHandle = savedOut
        CLIOut.stderrHandle = savedErr
        try? outHandle.close()
        try? errHandle.close()
        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: directory)
        return CLIRun(stdout: out, stderr: err, code: code)
    }
}
