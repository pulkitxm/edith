import AppKit
import ArgumentParser
import Darwin
import Dispatch
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

enum CLIProcessProbeError: Error, Equatable, LocalizedError {
    case timedOut(executable: String, arguments: [String], seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .timedOut(executable, arguments, seconds):
            return
                "\(([executable] + arguments).joined(separator: " ")) timed out after \(seconds) seconds"
        }
    }
}

enum CLIProcessProbe {
    static let defaultTimeout: TimeInterval = 15
    private static let terminationGrace: TimeInterval = 2
    private static let processGroupScript = """
        set -m
        "$@" &
        child=$!
        set +m
        terminate_group() {
            if kill -TERM -"$child" 2>/dev/null; then
                sleep 1
                kill -KILL -"$child" 2>/dev/null || :
            fi
        }
        trap 'terminate_group; exit 124' TERM INT
        wait "$child"
        status=$?
        terminate_group
        trap - TERM INT
        exit "$status"
        """

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static var binary: URL {
        packageRoot.appendingPathComponent(".build/debug/ed")
    }

    static func run(
        _ arguments: [String], executable: URL? = nil, currentDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = defaultTimeout
    ) throws -> CLIRun {
        let target = executable ?? binary
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-cli-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: captureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let stdoutURL = captureDirectory.appendingPathComponent("stdout")
        let stderrURL = captureDirectory.appendingPathComponent("stderr")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments =
            [
                "-c", processGroupScript, "cli-process-probe", target.path,
            ] + arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + max(0, timeout)) == .success else {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + terminationGrace) == .timedOut,
                process.isRunning
            {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + terminationGrace)
            }
            throw CLIProcessProbeError.timedOut(
                executable: target.path, arguments: arguments, seconds: timeout)
        }
        try stdout.close()
        try stderr.close()
        let out = try Data(contentsOf: stdoutURL)
        let err = try Data(contentsOf: stderrURL)
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
    private(set) var revealedURLs: [[URL]] = []
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
        let historyURL = sandbox.appendingPathComponent("update-checks.json")
        CLIEnvironment.updateHistoryURL = { historyURL }
        CLIEnvironment.homeDirectory = sandbox
        CLIEnvironment.clipboardPasteboard = pasteboard
        CLIEnvironment.downloadQueueFile = sandbox.appendingPathComponent("downloads.json")
        shared = UserDefaults(suiteName: suite)!
        standard = UserDefaults(suiteName: suite + ".standard")!
        shared.removePersistentDomain(forName: suite)
        standard.removePersistentDomain(forName: suite + ".standard")
        CLIEnvironment.sharedDefaults = shared
        CLIEnvironment.standardDefaults = standard
        CLIEnvironment.isHelperRunning = { false }
        CLIEnvironment.isMainAppRunning = { false }
        CLIEnvironment.executableNamed = { _ in nil }
        CLIEnvironment.homebrewClient = { HomebrewClient(executableURL: nil) }
        QuinjetCLIEnvironment.client = {
            QuinjetClient { _ in throw QuinjetClientError.notInstalled }
        }
        CLIEnvironment.installedAppURL = { nil }
        CLIEnvironment.appContributors = { [] }
        CLIEnvironment.appInspectionCenter = { [weak self] in
            AppInspectionCenter(
                exists: { _ in false }, createDirectory: { _ in },
                open: { url in
                    self?.note(url: url)
                    return true
                },
                reveal: { self?.note(revealed: $0) }, idleWakeups: { 0 })
        }
        CLIEnvironment.resolveCompanionEndpoint = {
            CompanionClient.endpoint(override: $0 ?? "http://127.0.0.1:1")
        }
        CLIEnvironment.companionConfigured = { false }
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

    private func note(revealed urls: [URL]) {
        lock.lock()
        revealedURLs.append(urls)
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

    func opened() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return openedURLs
    }

    func recordedURLs() -> [URL] {
        opened()
    }

    func revealed() -> [[URL]] {
        lock.lock()
        defer { lock.unlock() }
        return revealedURLs
    }

    func appPaths(existing: Set<URL>) {
        CLIEnvironment.appInspectionCenter = { [weak self] in
            AppInspectionCenter(
                exists: { existing.contains($0) }, createDirectory: { _ in },
                open: { url in
                    self?.note(url: url)
                    return true
                },
                reveal: { self?.note(revealed: $0) }, idleWakeups: { 0 })
        }
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
