import AppKit
import Darwin
import Foundation

public enum CaptureScreenshotError: LocalizedError, Equatable {
    case busy
    case cancelled
    case captureFailed(Int32)
    case saveFailed

    public var errorDescription: String? {
        switch self {
        case .busy: "A screen selection is already active."
        case .cancelled: "Screen selection was cancelled."
        case .captureFailed(let status): "Screen capture failed with status \(status)."
        case .saveFailed: "The screenshot could not be saved."
        }
    }
}

public final class CaptureScreenshotSession: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var processID: pid_t?
    private var cancellationRequested = false

    public init() {}

    public func capture() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-capture-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try reserve()
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try captureSynchronously(at: url)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            cancel()
        }
    }

    public func cancel() {
        let processID = lock.withLock {
            cancellationRequested = true
            return self.processID
        }
        if let processID { _ = kill(-processID, SIGTERM) }
    }

    private func reserve() throws {
        try lock.withLock {
            guard !active else { throw CaptureScreenshotError.busy }
            active = true
            cancellationRequested = false
        }
    }

    private func release(_ processID: pid_t?) {
        lock.withLock {
            if processID == nil || self.processID == processID {
                active = false
                self.processID = nil
                cancellationRequested = false
            }
        }
    }

    private func captureSynchronously(at url: URL) throws -> URL {
        var launchedProcessID: pid_t?
        var completed = false
        defer {
            release(launchedProcessID)
            if !completed { try? FileManager.default.removeItem(at: url) }
        }
        let processID = try spawn(
            executable: "/usr/sbin/screencapture", arguments: ["-i", "-x", url.path])
        launchedProcessID = processID
        let shouldCancel = lock.withLock {
            self.processID = processID
            return cancellationRequested
        }
        if shouldCancel || Task.isCancelled { _ = kill(-processID, SIGTERM) }
        let status = try waitForExit(processID)
        let cancelled = lock.withLock { cancellationRequested } || Task.isCancelled
        if cancelled { throw CaptureScreenshotError.cancelled }
        guard status == 0 else {
            throw status == 1
                ? CaptureScreenshotError.cancelled : CaptureScreenshotError.captureFailed(status)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureScreenshotError.saveFailed
        }
        completed = true
        return url
    }

    private func waitForExit(_ processID: pid_t) throws -> Int32 {
        var waitStatus: Int32 = 0
        var cancellationDeadline: Date?
        while true {
            let result = waitpid(processID, &waitStatus, WNOHANG)
            if result == processID { return terminationStatus(waitStatus) }
            if result == -1, errno != EINTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let cancelled = lock.withLock { cancellationRequested } || Task.isCancelled
            if cancelled {
                if cancellationDeadline == nil {
                    _ = kill(-processID, SIGTERM)
                    cancellationDeadline = Date().addingTimeInterval(0.5)
                } else if let cancellationDeadline, Date() >= cancellationDeadline {
                    _ = kill(-processID, SIGKILL)
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func spawn(executable: String, arguments: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        var processID: pid_t = 0
        let initStatus = posix_spawnattr_init(&attributes)
        guard initStatus == 0 else { throw posixError(initStatus) }
        defer { posix_spawnattr_destroy(&attributes) }
        let flagsStatus = posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP))
        guard flagsStatus == 0 else { throw posixError(flagsStatus) }
        let groupStatus = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupStatus == 0 else { throw posixError(groupStatus) }
        let storage = ([executable] + arguments).map { strdup($0) }
        guard storage.allSatisfy({ $0 != nil }) else {
            storage.compactMap { $0 }.forEach { free($0) }
            throw CocoaError(.fileWriteOutOfSpace)
        }
        defer { storage.compactMap { $0 }.forEach { free($0) } }
        var pointers = storage + [nil]
        let spawnStatus = executable.withCString { executablePath in
            pointers.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processID, executablePath, nil, &attributes, buffer.baseAddress, environ)
            }
        }
        guard spawnStatus == 0 else { throw posixError(spawnStatus) }
        return processID
    }

    private func terminationStatus(_ waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : signal
    }

    private func posixError(_ status: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(status))
    }
}

public enum CaptureScreenshotArchive {
    public static func save(_ source: URL, now: Date = Date()) throws -> URL {
        let data = try Data(contentsOf: source)
        return try save(data, now: now)
    }

    public static func save(_ data: Data, now: Date = Date()) throws -> URL {
        guard
            let pictures = FileManager.default.urls(
                for: .picturesDirectory, in: .userDomainMask
            ).first
        else { throw CaptureScreenshotError.saveFailed }
        let directory = pictures.appendingPathComponent("Edith Captures", isDirectory: true)
        return try save(data, to: directory, now: now)
    }

    public static func save(_ data: Data, to directory: URL, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Edith Capture \(formatter.string(from: now))"
        var destination = directory.appendingPathComponent(name).appendingPathExtension("png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination =
                directory
                .appendingPathComponent("\(name) \(suffix)")
                .appendingPathExtension("png")
            suffix += 1
        }
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            throw CaptureScreenshotError.saveFailed
        }
    }
}

public enum CaptureScreenshotImage {
    public static func load(_ url: URL) throws -> CGImage {
        guard let source = NSImage(contentsOf: url),
            let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw CaptureRecognitionError.unreadableImage }
        return image
    }
}
