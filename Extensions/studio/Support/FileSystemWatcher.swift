import CoreServices
import Foundation

public enum FileSystemWatchPolicy {
    public static func shouldFire(
        lastFired: Date?, now: Date, debounce: TimeInterval
    ) -> Bool {
        guard let lastFired else { return true }
        return now.timeIntervalSince(lastFired) >= debounce
    }

    public static func existingPaths(
        _ paths: [URL], fileManager: FileManager = .default
    ) -> [String] {
        paths.map(\.path).filter { fileManager.fileExists(atPath: $0) }
    }
}

public final class FileSystemWatcher: @unchecked Sendable {
    private let paths: [String]
    private let debounce: TimeInterval
    private let eventLatency: TimeInterval
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void
    private let lock = NSRecursiveLock()
    private var generation = 0
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var burstDeadline: DispatchTime?

    public init(
        paths: [URL], debounce: TimeInterval = 30, eventLatency: TimeInterval = 5,
        queue: DispatchQueue = DispatchQueue(label: "studio.fsevents"),
        handler: @escaping @Sendable () -> Void
    ) {
        self.paths = FileSystemWatchPolicy.existingPaths(paths)
        self.debounce = debounce
        self.eventLatency = eventLatency
        self.queue = queue
        self.handler = handler
    }

    public var isWatching: Bool { lock.withLock { stream != nil } }

    public var watchedPaths: [String] { paths }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil,
            release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.schedule()
        }
        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), eventLatency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        pending?.cancel()
        pending = nil
        burstDeadline = nil
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func schedule() {
        lock.lock()
        let eventGeneration = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.stream != nil, self.generation == eventGeneration else { return }
            let now = DispatchTime.now()
            let deadline = self.burstDeadline ?? now + self.debounce * 4
            self.burstDeadline = deadline
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.stream != nil, self.generation == eventGeneration else { return }
                self.burstDeadline = nil
                self.pending = nil
                self.handler()
            }
            self.pending = work
            self.queue.asyncAfter(deadline: min(now + self.debounce, deadline), execute: work)
        }
    }

    deinit { stop() }
}
