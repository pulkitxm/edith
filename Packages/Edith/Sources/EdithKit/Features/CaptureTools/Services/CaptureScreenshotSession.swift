import AppKit
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
    private var process: Process?

    public init() {}

    public func capture() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-capture-\(UUID().uuidString)")
            .appendingPathExtension("png")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", url.path]
                process.terminationHandler = { [weak self] completed in
                    self?.release(completed)
                    if completed.terminationStatus == 0,
                        FileManager.default.fileExists(atPath: url.path)
                    {
                        continuation.resume(returning: url)
                    } else {
                        try? FileManager.default.removeItem(at: url)
                        let error: CaptureScreenshotError =
                            completed.terminationStatus == 1
                            ? .cancelled : .captureFailed(completed.terminationStatus)
                        continuation.resume(throwing: error)
                    }
                }
                do {
                    try prepare(process)
                    guard !Task.isCancelled else {
                        release(process)
                        throw CaptureScreenshotError.cancelled
                    }
                    try process.run()
                } catch {
                    release(process)
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    public func cancel() {
        let active = lock.withLock { process }
        if active?.isRunning == true { active?.terminate() }
    }

    private func prepare(_ process: Process) throws {
        try lock.withLock {
            guard self.process == nil else { throw CaptureScreenshotError.busy }
            self.process = process
        }
    }

    private func release(_ process: Process) {
        lock.withLock {
            if self.process === process { self.process = nil }
        }
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
            destination = directory
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
