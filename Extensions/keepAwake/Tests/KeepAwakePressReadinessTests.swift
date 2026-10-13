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

    var baselineAccessibilityValue: Int? { hasValue ? initialValue : nil }

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

struct KeepAwakePressFailure: Error, CustomStringConvertible {
    let description: String
}

enum KeepAwakePressDiagnostics {
    static let fields = [
        "uiPreventSleep", "enginePreventSleep", "statusAvailable", "preventingSleep",
        "operationCount", "modelReady", "modelRunning", "modelError", "modelBusy", "assertionCount",
    ]
    static let flags: Set<String> = [
        "controlAvailable", "roleMatched", "labelMatched", "identifierMatched", "enabled",
        "element",
        "selectorPresent", "selectorAllowed", "protocolConforms", "modelIdle",
    ]

    static func encode(
        attempts: Int, accepted: Bool, baseline: [Int], current: [Int]?,
        baselineValue: Int?, currentValue: Int?, flags: [String: Bool]
    ) -> String {
        guard attempts >= 0, baseline.count == fields.count,
            current == nil || current?.count == fields.count, Set(flags.keys) == Self.flags
        else { return "{\"diagnosticEncodingFailed\":true}" }
        let changed = current.map { value in baseline.indices.filter { baseline[$0] != value[$0] } }
        let values: [String: Any] = [
            "pressAttempts": attempts, "pressAccepted": accepted, "fields": fields,
            "baseline": baseline, "current": current as Any? ?? NSNull(),
            "changed": changed as Any? ?? NSNull(),
            "baselineAXValue": baselineValue as Any? ?? NSNull(),
            "currentAXValue": currentValue as Any? ?? NSNull(), "flags": flags,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys),
            data.count <= 1024, let text = String(data: data, encoding: .utf8)
        else { return "{\"diagnosticEncodingFailed\":true}" }
        return text
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
    @Test func pressDiagnosticsDistinguishStartupRefreshFromRejectedMutationWithinTheBound() throws
    {
        let before = [0, 0, 1, 0, 1, 1, 1, 0, 0, 0]
        var refresh = before
        refresh[4] = 2
        refresh[8] = 1
        var mutated = before
        mutated[0] = 1
        let flags = Dictionary(
            uniqueKeysWithValues: KeepAwakePressDiagnostics.flags.map { ($0, true) })
        for (current, expected) in [(refresh, [4, 8]), (mutated, [0])] {
            let encoded = KeepAwakePressDiagnostics.encode(
                attempts: 1, accepted: false, baseline: before, current: current,
                baselineValue: 0, currentValue: current[0], flags: flags)
            #expect(encoded.utf8.count <= 1024)
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
            #expect(object["baseline"] as? [Int] == before)
            #expect(object["current"] as? [Int] == current)
            #expect(object["changed"] as? [Int] == expected)
            #expect(object["pressAccepted"] as? Bool == false)
            #expect(object["currentAXValue"] as? Int == current[0])
        }
    }

    @Test func pressDiagnosticsRejectUnknownOrUnboundedVectorsAndRepresentMissingReadback() throws {
        let flags = Dictionary(
            uniqueKeysWithValues: KeepAwakePressDiagnostics.flags.map { ($0, false) })
        let rejected = "{\"diagnosticEncodingFailed\":true}"
        #expect(
            KeepAwakePressDiagnostics.encode(
                attempts: 0, accepted: false, baseline: Array(repeating: 0, count: 4096),
                current: nil,
                baselineValue: nil, currentValue: nil, flags: flags) == rejected)
        var unknown = flags
        unknown["unbounded-" + String(repeating: "x", count: 4096)] = true
        #expect(
            KeepAwakePressDiagnostics.encode(
                attempts: 0, accepted: false, baseline: Array(repeating: 0, count: 10),
                current: nil,
                baselineValue: nil, currentValue: nil, flags: unknown) == rejected)
        let encoded = KeepAwakePressDiagnostics.encode(
            attempts: 0, accepted: false, baseline: Array(repeating: 0, count: 10), current: nil,
            baselineValue: nil, currentValue: nil, flags: flags)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        #expect(object["current"] is NSNull)
        #expect(object["baselineAXValue"] is NSNull)
        #expect(object["currentAXValue"] is NSNull)
        #expect(encoded.utf8.count <= 1024)
    }

}
