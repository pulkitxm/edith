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
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var burstDeadline: DispatchTime?

    public init(
        paths: [URL], debounce: TimeInterval = 30,
        queue: DispatchQueue = DispatchQueue(label: "com.pulkit.edith.agent.fsevents"),
        handler: @escaping @Sendable () -> Void
    ) {
        self.paths = FileSystemWatchPolicy.existingPaths(paths)
        self.debounce = debounce
        self.queue = queue
        self.handler = handler
    }

    public var isWatching: Bool { stream != nil }

    public var watchedPaths: [String] { paths }

    public func start() {
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
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5.0,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        pending?.cancel()
        pending = nil
        burstDeadline = nil
    }

    private func schedule() {
        queue.async { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now()
            let deadline = self.burstDeadline ?? now + self.debounce * 4
            self.burstDeadline = deadline
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.burstDeadline = nil
                self?.handler()
            }
            self.pending = work
            self.queue.asyncAfter(deadline: min(now + self.debounce, deadline), execute: work)
        }
    }

    deinit { stop() }
}

public enum UsageWatchPaths {
    public static func directories(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [home.appendingPathComponent(".claude"), home.appendingPathComponent(".codex")]
    }
}
