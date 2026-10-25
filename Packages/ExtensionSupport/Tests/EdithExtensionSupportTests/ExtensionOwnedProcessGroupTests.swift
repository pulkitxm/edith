import Darwin
import Foundation
import Testing

@testable import EdithExtensionSupport

@Suite struct ExtensionOwnedProcessGroupTests {
    private final class Kernel: @unchecked Sendable {
        private let lock = NSLock()
        private var identities: [Int32: ExtensionProcessIdentity] = [:]
        private var groups: [Int32: Int32] = [:]
        private var unreadable = Set<Int32>()
        private var failedScan = false
        private var sent: [Int32] = []
        private var joins = 0
        private var joinAllowed = false

        func add(_ pid: Int32, generation: String, group: Int32? = nil) throws {
            let birth = try JSONDecoder().decode(
                ExtensionProcessIdentity.self,
                from: JSONSerialization.data(withJSONObject: ["pid": pid, "generation": generation])
            )
            lock.withLock {
                identities[pid] = birth; groups[pid] = group ?? pid
            }
        }

        func remove(_ pid: Int32) {
            lock.withLock {
                identities[pid] = nil; groups[pid] = nil
            }
        }
        func hide(_ pid: Int32) {
            lock.withLock {
                identities[pid] = nil; unreadable.insert(pid)
            }
        }
        func allowJoin() { lock.withLock { joinAllowed = true } }
        func failScan(_ value: Bool) { lock.withLock { failedScan = value } }
        var signals: [Int32] { lock.withLock { sent } }
        var joinCount: Int { lock.withLock { joins } }
        func birth(_ pid: Int32) -> ExtensionProcessIdentity? { lock.withLock { identities[pid] } }

        func token() throws -> ExtensionOwnedProcessGroup {
            let leader = try #require(birth(1234))
            return try ExtensionOwnedProcessGroup(
                leader: leader, read: { self.birth($0) },
                group: { pid in self.lock.withLock { self.groups[pid] ?? -1 } },
                members: { group in
                    try self.lock.withLock {
                        guard !self.failedScan else { throw CocoaError(.fileReadUnknown) }
                        return self.groups.filter { $0.value == group }.map(\.key)
                    }
                }, descendants: { _ in [] },
                exists: { pid in
                    self.lock.withLock {
                        self.identities[pid] != nil || self.unreadable.contains(pid)
                    }
                },
                send: { target, _ in
                    self.lock.withLock {
                        self.sent.append(target); return 0
                    }
                })
        }

        func join() async throws {
            lock.withLock { joins += 1 }
            let deadline = ContinuousClock.now + .seconds(2)
            while !lock.withLock({ joinAllowed }) {
                guard ContinuousClock.now < deadline else { throw CocoaError(.executableLoad) }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    @Test func lateUnknownMemberAfterLeaderExitRetainsAuthorityWithoutSignalling() async throws {
        let kernel = Kernel()
        try kernel.add(1234, generation: "1.0")
        let token = try kernel.token()
        try kernel.add(1235, generation: "1.1", group: 1234)
        kernel.remove(1234)
        #expect(try !token.refreshObserved())
        try token.signal()
        #expect(kernel.signals.isEmpty)
        #expect(token.observedBirths.count == 1)
        await #expect(throws: (any Error).self) {
            try await token.retire(after: {}, timeout: .milliseconds(20))
        }
        #expect(!token.isRetired)
        kernel.remove(1235)
        try await token.retire(after: {}, timeout: .milliseconds(20))
        #expect(token.isRetired)
    }

    @Test func joinedLeaderCannotReleaseWhileCapturedDescendantStillLives() async throws {
        let kernel = Kernel()
        try kernel.add(1234, generation: "1.0")
        try kernel.add(1235, generation: "1.1", group: 1234)
        let token = try kernel.token()
        kernel.remove(1234)
        await #expect(throws: (any Error).self) {
            try await token.retire(after: {}, timeout: .milliseconds(20))
        }
        #expect(!token.isRetired)
        #expect(kernel.signals.isEmpty)
        kernel.remove(1235)
        try await token.retire(after: {}, timeout: .milliseconds(20))
        #expect(token.isRetired)
    }

    @Test func unreadableBirthAndFailedMembershipScanNeverBecomeAbsence() throws {
        let kernel = Kernel()
        try kernel.add(1234, generation: "1.0")
        let token = try kernel.token()
        kernel.hide(1234)
        #expect(try !token.refreshObserved())
        try token.signal()
        #expect(kernel.signals.isEmpty)
        kernel.failScan(true)
        #expect(throws: (any Error).self) { try token.refreshObserved() }
        #expect(!token.isRetired)
    }

    @Test func reusedGroupNeverProvidesSignalAuthority() throws {
        let kernel = Kernel()
        try kernel.add(1234, generation: "1.0")
        let token = try kernel.token()
        try kernel.add(1234, generation: "2.0")
        #expect(try !token.refreshObserved())
        try token.signal()
        #expect(kernel.signals.isEmpty)
        kernel.remove(1234)
        #expect(try token.refreshObserved())
    }

    @Test func cancellationAndSecondRetireJoinOneActualCleanupTask() async throws {
        let kernel = Kernel()
        try kernel.add(1234, generation: "1.0")
        let token = try kernel.token()
        let first = Task { try await token.retire(after: { try await kernel.join() }) }
        defer { kernel.allowJoin() }
        let deadline = ContinuousClock.now + .seconds(2)
        while kernel.joinCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        try #require(kernel.joinCount == 1)
        first.cancel()
        let second = Task { try await token.retire(after: { try await kernel.join() }) }
        for _ in 0..<100 { await Task.yield() }
        #expect(kernel.joinCount == 1)
        #expect(!token.isRetired)
        kernel.remove(1234)
        kernel.allowJoin()
        let finishDeadline = ContinuousClock.now + .seconds(2)
        while !token.isRetired, ContinuousClock.now < finishDeadline { await Task.yield() }
        try #require(token.isRetired)
        try await first.value
        try await second.value
        #expect(kernel.joinCount == 1)
    }
}
