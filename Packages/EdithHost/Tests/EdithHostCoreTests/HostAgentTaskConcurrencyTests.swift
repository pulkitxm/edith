import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostAgentTaskConcurrencyTests {
    @Test func blockedOperationsAndKeepsTheirSubmissionOrder() async throws {
        let fixture = try await TaskConcurrencyFixture(concurrency: 2)
        let serial = try await fixture.submit("serial", names: ["s0", "s1", "s2"])
        let other = try await fixture.submit("other", names: ["o0"])
        try await fixture.waitFor(["s0", "o0"])
        #expect(try await fixture.client.status(serial[1].id).snapshot.state == .queued)
        #expect(try await fixture.client.status(serial[2].id).snapshot.state == .queued)
        await fixture.gate.release("s0")
        try await fixture.waitFor(["s0", "o0", "s1"])
        #expect(await fixture.gate.names.filter { $0.hasPrefix("s") } == ["s0", "s1"])
        await fixture.gate.release("o0")
        _ = try await fixture.finished(other[0].id)
        #expect(try await fixture.client.status(serial[2].id).snapshot.state == .queued)
        let following = try await fixture.submit("other", names: ["o1"])
        try await fixture.waitFor(["s0", "o0", "s1", "o1"])
        await fixture.gate.release("s1")
        try await fixture.waitFor(["s0", "o0", "s1", "o1", "s2"])
        #expect(await fixture.gate.names.filter { $0.hasPrefix("s") } == ["s0", "s1", "s2"])
        #expect(await fixture.gate.maximum == 2)
        await fixture.gate.release("o1")
        await fixture.gate.release("s2")
        for task in serial + following { _ = try await fixture.finished(task.id) }
        await fixture.service.shutdown()
    }

    @Test func cancellationKeepsTheOperationSlotUntilItsWorkerFinishes() async throws {
        let fixture = try await TaskConcurrencyFixture(concurrency: 3)
        let serial = try await fixture.submit("serial", names: ["s0", "s1", "s2"])
        let other = try await fixture.submit("other", names: ["o0", "o1"])
        try await fixture.waitFor(["s0", "o0", "o1"])
        #expect(try await fixture.client.cancel(serial[0].id).state == .cancelling)
        #expect(try await fixture.client.cancel(serial[1].id).state == .cancelled)
        await fixture.gate.release("o0")
        _ = try await fixture.finished(other[0].id)
        #expect(try await fixture.client.status(serial[2].id).snapshot.state == .queued)
        #expect(await !fixture.gate.names.contains("s1"))
        await fixture.gate.release("s0")
        try await fixture.waitFor(["s0", "o0", "o1", "s2"])
        #expect(try await fixture.client.status(serial[0].id).snapshot.state == .cancelled)
        #expect(await !fixture.gate.names.contains("s1"))
        await fixture.gate.release("s2")
        await fixture.gate.release("o1")
        _ = try await fixture.finished(serial[2].id)
        _ = try await fixture.finished(other[1].id)
        await fixture.service.shutdown()
    }

    @Test func changingLimitsAdmitsEligibleWorkWithoutExceedingTheGlobalLimit() async throws {
        let fixture = try await TaskConcurrencyFixture(concurrency: 2)
        let serial = try await fixture.submit("serial", names: ["s0", "s1", "s2"])
        try await fixture.waitFor(["s0"])
        await fixture.registerSerial(concurrency: 99)
        try await fixture.waitFor(["s0", "s1"])
        #expect(await fixture.gate.maximum == 2)
        await fixture.registerSerial(concurrency: 0)
        await fixture.gate.release("s0")
        _ = try await fixture.finished(serial[0].id)
        #expect(try await fixture.client.status(serial[2].id).snapshot.state == .queued)
        await fixture.gate.release("s1")
        try await fixture.waitFor(["s0", "s1", "s2"])
        await fixture.gate.release("s2")
        _ = try await fixture.finished(serial[2].id)
        await fixture.service.shutdown()
    }

    @Test func theCapFollowsTheMachineAndReservesOneSlot() async throws {
        let cap = HostAgentTaskLimits.machineCap
        #expect(HostAgentTaskLimits(concurrency: 10_000).concurrency == cap)
        #expect(cap >= 4)
        guard cap > 4 else { return }
        let fixture = try await TaskConcurrencyFixture(concurrency: cap)
        await fixture.registerSerial(concurrency: cap)
        let names = (0..<(cap - 1)).map { "s\($0)" }
        _ = try await fixture.submit("serial", names: names + ["held"])
        try await fixture.waitFor(Set(names))
        try await Task.sleep(for: .milliseconds(80))
        #expect(await fixture.gate.names.contains("held") == false)
        _ = try await fixture.submit("other", names: ["o0"])
        try await fixture.waitFor(Set(names).union(["o0"]))
        #expect(await fixture.gate.names.contains("held") == false)
        #expect(await fixture.gate.maximum == cap)
        await fixture.gate.release("held")
        for name in names { await fixture.gate.release(name) }
        await fixture.gate.release("o0")
        await fixture.service.shutdown()
    }
}

private struct TaskConcurrencyFixture {
    let service: HostAgentTaskService
    var client: HostAgentTaskService { service }
    let gate: TaskConcurrencyGate

    init(concurrency: Int) async throws {
        let gate = TaskConcurrencyGate()
        let service = try HostAgentTaskService(
            directory: nil, limits: HostAgentTaskLimits(concurrency: concurrency))
        await service.register(operation: "serial", concurrency: 1) { data, _ in
            await gate.enter(String(decoding: data, as: UTF8.self))
            return data
        }
        await service.register(operation: "other") { data, _ in
            await gate.enter(String(decoding: data, as: UTF8.self))
            return data
        }
        self.service = service
        self.gate = gate
    }

    func registerSerial(concurrency: Int) async {
        await service.register(operation: "serial", concurrency: concurrency) { [gate] data, _ in
            await gate.enter(String(decoding: data, as: UTF8.self))
            return data
        }
    }

    func submit(_ operation: String, names: [String]) async throws -> [HostAgentTaskSnapshot] {
        var snapshots: [HostAgentTaskSnapshot] = []
        for name in names {
            snapshots.append(
                try await client.submit(
                    HostAgentTaskSubmission(
                        operation: operation, title: name, payload: Data(name.utf8))))
        }
        return snapshots
    }

    func waitFor(_ names: Set<String>) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await names.isSubset(of: Set(gate.names))), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let observed = await Set(gate.names)
        try #require(names.isSubset(of: observed))
    }

    func finished(_ id: UUID) async throws -> HostAgentTaskStatus {
        let deadline = Date().addingTimeInterval(3)
        var status = try await client.status(id)
        while !status.snapshot.state.isTerminal, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
            status = try await client.status(id)
        }
        try #require(status.snapshot.state.isTerminal)
        return status
    }
}

private actor TaskConcurrencyGate {
    private(set) var names: [String] = []
    private(set) var maximum = 0
    private var released: Set<String> = []
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]

    func enter(_ name: String) async {
        names.append(name)
        if released.remove(name) != nil { return }
        await withCheckedContinuation { continuation in
            continuations[name] = continuation
            maximum = max(maximum, continuations.count)
        }
    }

    func release(_ name: String) {
        if let continuation = continuations.removeValue(forKey: name) {
            continuation.resume()
        } else {
            released.insert(name)
        }
    }
}
