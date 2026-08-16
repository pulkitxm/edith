import AppKit
import EdithKit
import Foundation

public enum AppBridge {
    public static let helperBundleID = MainApp.statusBarBundleIdentifier
    public static let mainBundleID = MainApp.bundleIdentifier
    public static let filesBundleID = MainApp.filesBundleIdentifier
    public static let filesBundlePath = "Contents/Library/Applications/Edith Files.app"

    public static var helperIsRunning: Bool { CLIEnvironment.isHelperRunning() }

    public static var mainAppIsRunning: Bool { CLIEnvironment.isMainAppRunning() }

    public static var filesAppIsRunning: Bool { CLIEnvironment.isFilesAppRunning() }

    public static func filesAppURL() -> URL? {
        guard let bundle = CLIEnvironment.installedAppURL() else { return nil }
        let files = bundle.appendingPathComponent(filesBundlePath)
        return FileManager.default.fileExists(atPath: files.path) ? files : nil
    }

    public static func requireHelper(_ what: String) throws {
        guard helperIsRunning else {
            throw CLIFailure.unavailable(
                "\(what) needs the Edith menu bar app to be running",
                hint: "start Edith, then retry")
        }
    }

    public static func requireMainApp(_ what: String) throws {
        guard mainAppIsRunning else {
            throw CLIFailure.unavailable(
                "\(what) needs the Edith main window to be open",
                hint: "run `ed app relaunch`, or open Edith from the menu bar")
        }
    }

    public static func post(_ name: Notification.Name, userInfo: [String: Any]? = nil) {
        CLIEnvironment.deliver(name, userInfo)
    }

    public static func startFilesApp(
        machineID: UUID, path: String?, within seconds: TimeInterval = 20
    ) async throws {
        guard let bundle = filesAppURL() else {
            throw CLIFailure.unavailable(
                "Edith Files is not installed where ed can find it",
                hint: "it lives inside Edith.app; reinstall Edith and retry")
        }
        var arguments = [FilesLaunch.machineFlag, machineID.uuidString]
        if let path, !path.isEmpty { arguments += [FilesLaunch.pathFlag, path] }
        do {
            try await EdithProcesses.launch(bundle, arguments: arguments)
        } catch {
            throw CLIFailure.unavailable(
                "could not start Edith Files: \(error.localizedDescription)",
                hint: "open \(bundle.path) from Finder, then retry")
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if filesAppIsRunning { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw CLIFailure.unavailable(
            "Edith Files did not come up in time",
            hint: "open \(bundle.path) from Finder, then retry")
    }

    public static func silence(
        _ what: String, extensionKey: String? = nil, permission: String? = nil
    ) -> CLIFailure {
        guard helperIsRunning else {
            return CLIFailure.unavailable(
                "Edith is not running, so it cannot answer for \(what)",
                hint: "open Edith and try again")
        }
        if let extensionKey,
            !(CLIEnvironment.sharedDefaults.object(forKey: extensionKey) as? Bool ?? false)
        {
            return CLIFailure.unavailable(
                "the extension behind \(what) is off",
                hint: "run `ed extensions ls` to see which are enabled")
        }
        if let permission,
            let usage = CLIEnvironment.permissionUsages().first(where: {
                $0.permission.rawValue == permission
            }), !usage.isGranted
        {
            return CLIFailure.unavailable(
                "macOS has not granted Edith access for \(what)",
                hint: "run `ed permissions request \(permission)`")
        }
        return CLIFailure.unavailable(
            "Edith did not answer for \(what) in time",
            hint: "the running app may predate this command; rebuild and reopen Edith")
    }

    public static func awaitReply(
        _ name: Notification.Name, timeout: TimeInterval,
        trigger: @escaping @Sendable () -> Void
    ) async -> [AnyHashable: Any]? {
        if let answer = CLIEnvironment.answer {
            trigger()
            return answer(name)
        }
        let waiter = ReplyWaiter()
        let token = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { note in
            waiter.deliver(note.userInfo ?? [:])
        }
        defer { DistributedNotificationCenter.default().removeObserver(token) }
        trigger()
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(max(0, timeout)))
            guard !Task.isCancelled else { return }
            waiter.cancel()
        }
        let noteTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !waiter.isFinished else { return }
            CLIOut.note("waiting for Edith to answer...")
        }
        let value = await waiter.wait()
        timeoutTask.cancel()
        noteTask.cancel()
        return value
    }
}

private struct ReplyValue: @unchecked Sendable {
    let payload: [AnyHashable: Any]
}

final class ReplyWaiter: @unchecked Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<ReplyValue?, Never>)
        case finished(ReplyValue?)
    }

    private let lock = NSLock()
    private var state = State.idle

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .finished = state { return true }
        return false
    }

    @discardableResult
    func deliver(_ payload: [AnyHashable: Any]) -> Bool {
        finish(ReplyValue(payload: payload))
    }

    @discardableResult
    func cancel() -> Bool {
        finish(nil)
    }

    func wait() async -> [AnyHashable: Any]? {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            cancel()
        }
        return result?.payload
    }

    private func install(_ continuation: CheckedContinuation<ReplyValue?, Never>) {
        var completed: ReplyValue??
        lock.lock()
        switch state {
        case .idle:
            state = .waiting(continuation)
        case let .finished(value):
            completed = value
        case .waiting:
            completed = .some(nil)
        }
        lock.unlock()
        if let completed { continuation.resume(returning: completed) }
    }

    private func finish(_ value: ReplyValue?) -> Bool {
        var continuation: CheckedContinuation<ReplyValue?, Never>?
        lock.lock()
        switch state {
        case .idle:
            state = .finished(value)
        case let .waiting(waiter):
            state = .finished(value)
            continuation = waiter
        case .finished:
            lock.unlock()
            return false
        }
        lock.unlock()
        continuation?.resume(returning: value)
        return true
    }
}
