import Foundation
import Testing

struct KeepAwakePressReadiness<Snapshot: Equatable> {
    enum Failure: Error {
        case changedOrBusy
    }

    let baseline: Snapshot
    private var hasValue = false
    private var initialValue: Int?
    private var accepted = false

    init(baseline: Snapshot) { self.baseline = baseline }

    func check(snapshot: Snapshot, idle: Bool) throws {
        guard snapshot == baseline, idle else { throw Failure.changedOrBusy }
    }

    mutating func attempt(
        ready: Bool, idle: Bool, value: Int?, perform: () -> Bool,
        snapshot: () throws -> Snapshot, readValue: () -> Int?
    ) throws -> Bool {
        if accepted { return true }
        try check(snapshot: snapshot(), idle: idle)
        if hasValue {
            guard value == initialValue else { throw Failure.changedOrBusy }
        }
        guard ready, let value else { return false }
        if !hasValue {
            initialValue = value
            hasValue = true
        }
        if perform() {
            accepted = true
            return true
        }
        try check(snapshot: snapshot(), idle: idle)
        guard readValue() == initialValue else { throw Failure.changedOrBusy }
        return false
    }
}

struct KeepAwakePressReadinessTests {
    @Test func delayedReadinessAndRejectedPressCanBecomeAcceptedExactlyOnce() throws {
        var gate = KeepAwakePressReadiness(baseline: 0)
        var calls = 0
        func press() -> Bool { calls += 1; return calls == 2 }
        for ready in [false, true, true, true] {
            let result = try gate.attempt(
                ready: ready, idle: true, value: 0, perform: press,
                snapshot: { 0 }, readValue: { 0 })
            #expect(result == (calls == 2))
        }
        #expect(calls == 2)
    }

    @Test func accessibilityValueCanAppearBeforeFirstReadyPress() throws {
        var gate = KeepAwakePressReadiness(baseline: 0)
        var calls = 0
        for ready in [false, true] {
            #expect(
                try !gate.attempt(
                    ready: ready, idle: true, value: nil,
                    perform: {
                        calls += 1; return true
                    },
                    snapshot: { 0 }, readValue: { nil }))
        }
        #expect(calls == 0)
        #expect(
            try gate.attempt(
                ready: true, idle: true, value: 0,
                perform: {
                    calls += 1; return true
                },
                snapshot: { 0 }, readValue: { 0 }))
        #expect(calls == 1)
    }

    @Test func missingReadinessNeverInvokesPress() throws {
        var gate = KeepAwakePressReadiness(baseline: 0)
        var calls = 0
        for _ in 0..<10 {
            #expect(
                try !gate.attempt(
                    ready: false, idle: true, value: 0,
                    perform: {
                        calls += 1; return true
                    },
                    snapshot: { 0 }, readValue: { 0 }))
        }
        #expect(calls == 0)
    }

    @Test func changedSnapshotOrBusyPresentationNeverInvokesPress() {
        for (snapshot, idle) in [(1, true), (0, false)] {
            var gate = KeepAwakePressReadiness(baseline: 0)
            var calls = 0
            #expect(throws: (any Error).self) {
                try gate.attempt(
                    ready: true, idle: idle, value: 0,
                    perform: {
                        calls += 1; return true
                    },
                    snapshot: { snapshot }, readValue: { 0 })
            }
            #expect(calls == 0)
        }
    }

    @Test func rejectedPressCannotMutatePreferencesOrAccessibilityValue() {
        for mutateValue in [false, true] {
            var gate = KeepAwakePressReadiness(baseline: 0)
            var state = 0
            var value = 0
            var calls = 0
            #expect(throws: (any Error).self) {
                try gate.attempt(
                    ready: true, idle: true, value: value,
                    perform: {
                        calls += 1
                        if mutateValue { value = 1 } else { state = 1 }
                        return false
                    }, snapshot: { state }, readValue: { value })
            }
            #expect(calls == 1)
            #expect(throws: (any Error).self) {
                try gate.attempt(
                    ready: true, idle: true, value: value,
                    perform: {
                        calls += 1; return true
                    }, snapshot: { state }, readValue: { value })
            }
            #expect(calls == 1)
        }
    }

    @Test func delayedMutationBetweenRejectedPressesPreventsAnotherAttempt() throws {
        var gate = KeepAwakePressReadiness(baseline: 0)
        var state = 0
        var calls = 0
        #expect(
            try !gate.attempt(
                ready: true, idle: true, value: 0,
                perform: {
                    calls += 1; return false
                },
                snapshot: { state }, readValue: { 0 }))
        state = 1
        #expect(throws: (any Error).self) {
            try gate.attempt(
                ready: true, idle: true, value: 0,
                perform: {
                    calls += 1; return true
                },
                snapshot: { state }, readValue: { 0 })
        }
        #expect(calls == 1)
    }

    @Test func acceptedPressCannotBeInvokedTwiceEvenAfterStateChanges() throws {
        var gate = KeepAwakePressReadiness(baseline: 0)
        var calls = 0
        #expect(
            try gate.attempt(
                ready: true, idle: true, value: 0,
                perform: {
                    calls += 1; return true
                },
                snapshot: { 0 }, readValue: { 0 }))
        #expect(
            try gate.attempt(
                ready: true, idle: false, value: 1,
                perform: {
                    calls += 1; return true
                },
                snapshot: { 1 }, readValue: { 1 }))
        #expect(calls == 1)
    }
}
