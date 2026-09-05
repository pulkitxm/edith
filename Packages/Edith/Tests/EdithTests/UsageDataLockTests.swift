import Darwin
import Foundation
import Testing

@testable import EdithKit

@Suite struct UsageDataLockTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-usage-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func lockRejectsSymlinksAndSpecialNodes() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = UsageDataLock.lockURL(dataDirectory: directory)
        let target = directory.appendingPathComponent("target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)

        #expect(throws: UsageDataLockError.unavailable(lockURL.path)) {
            try UsageDataLock.acquire(dataDirectory: directory)
        }

        try FileManager.default.removeItem(at: lockURL)
        #expect(mkfifo(lockURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        #expect(throws: UsageDataLockError.unavailable(lockURL.path)) {
            try UsageDataLock.acquire(dataDirectory: directory)
        }
    }

    @Test func regularFileReaderRejectsSymlinksFifosAndDevices() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let symlink = directory.appendingPathComponent("symlink")
        let fifo = directory.appendingPathComponent("fifo")
        try Data("safe".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        #expect(mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

        #expect(throws: UsageDataFileError.unsafe(symlink.path)) {
            try UsageDataFiles.readRegularFile(at: symlink)
        }
        #expect(throws: UsageDataFileError.unsafe(fifo.path)) {
            try UsageDataFiles.readRegularFile(at: fifo)
        }
        #expect(throws: UsageDataFileError.unsafe("/dev/null")) {
            try UsageDataFiles.readRegularFile(at: URL(fileURLWithPath: "/dev/null"))
        }
    }

    @Test func regularFileReaderEnforcesItsBound() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large")
        try Data(repeating: 1, count: 33).write(to: file)

        #expect(throws: UsageDataFileError.oversized(file.path)) {
            try UsageDataFiles.readRegularFile(at: file, maximumBytes: 32)
        }
    }

    @Test func concurrentReleaseIsIdempotent() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = try UsageDataLock.acquire(dataDirectory: directory)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { lock.release() }
            }
        }

        let reacquired = try UsageDataLock.acquire(dataDirectory: directory)
        reacquired.release()
    }

    @Test func concurrentTransactionReportsBusyWithoutPretendingToRefresh() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transactionURL = directory.appendingPathComponent("usage-transaction.lock")
        let refresh = try UsageDataLock.acquire(at: transactionURL)
        defer { refresh.release() }
        #expect(!UsageRefreshLock.isHeld(at: UsageRefreshRunner.lockURL(dataDir: directory)))

        #expect(throws: UsageDataTransactionError.refreshBusy) {
            try UsageDataTransaction.withExclusiveAccess(dataDirectory: directory) {}
        }
    }

    @Test func cancellingAContendedLockStopsWaitingAndKeepsTheOwner() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try UsageDataLock.acquire(dataDirectory: directory)
        defer { owner.release() }
        let waiting = Task.detached { try UsageDataLock.acquire(dataDirectory: directory) }
        try await Task.sleep(for: .milliseconds(60))
        let cancelledAt = ContinuousClock.now
        waiting.cancel()
        do {
            let unexpected = try await waiting.value
            unexpected.release()
            Issue.record("A cancelled waiter acquired the owned lock.")
        } catch is CancellationError {
            #expect(cancelledAt.duration(to: .now) < .seconds(1))
        }
        #expect(
            throws: UsageDataLockError.unavailable(
                UsageDataLock.lockURL(dataDirectory: directory).path)
        ) {
            try UsageDataLock.acquire(
                at: UsageDataLock.lockURL(dataDirectory: directory), nonblocking: true)
        }
        owner.release()
        let next = try UsageDataLock.acquire(dataDirectory: directory)
        next.release()
    }
}
