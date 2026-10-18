import Testing

struct KeepAwakeUIActionCompletion<Invariant: Equatable> {
    struct Observation {
        let binding: Int?
        let accessibilityValue: Int?
        let mutations: Int
        let invariant: Invariant
        let idle: Bool
    }

    enum Failure: Error {
        case invalidBaseline, changedOrBusy, noEffect, invalidValue, repeatedPress
    }

    let baseline: Observation
    let requested: Int
    private(set) var attempted = false
    private(set) var actionReturned: Bool?

    init(baseline: Observation, requested: Int) throws {
        guard let binding = baseline.binding, [0, 1].contains(binding),
            requested == 1 - binding, baseline.mutations >= 0, baseline.mutations < Int.max,
            baseline.idle
        else { throw Failure.invalidBaseline }
        self.baseline = baseline
        self.requested = requested
    }

    mutating func press(
        ready: Bool, observation: Observation, perform: () -> Bool,
        observe: () throws -> Observation
    ) throws -> Bool {
        guard !attempted else { throw Failure.repeatedPress }
        try unchanged(observation)
        guard observation.binding == baseline.binding,
            observation.mutations == baseline.mutations
        else { throw Failure.changedOrBusy }
        guard ready else { return false }
        guard observation.accessibilityValue == baseline.binding else { throw Failure.invalidValue }
        attempted = true
        actionReturned = perform()
        let result = try observe()
        guard result.binding == requested else { throw Failure.noEffect }
        return try complete(result)
    }

    func complete(_ observation: Observation) throws -> Bool {
        guard attempted else { throw Failure.noEffect }
        try unchanged(observation)
        guard observation.binding == requested,
            observation.mutations >= baseline.mutations,
            observation.mutations <= baseline.mutations + 1
        else { throw Failure.changedOrBusy }
        guard let value = observation.accessibilityValue,
            value == baseline.binding || value == requested
        else { throw Failure.invalidValue }
        return value == requested && observation.mutations == baseline.mutations + 1
    }

    private func unchanged(_ observation: Observation) throws {
        guard observation.invariant == baseline.invariant, observation.idle else {
            throw Failure.changedOrBusy
        }
    }
}

struct KeepAwakeUIActionCompletionTests {
    typealias Action = KeepAwakeUIActionCompletion<Int>

    private func observation(
        binding: Int? = 0, value: Int? = 0, mutations: Int = 0,
        invariant: Int = 7, idle: Bool = true
    ) -> Action.Observation {
        .init(
            binding: binding, accessibilityValue: value, mutations: mutations,
            invariant: invariant, idle: idle)
    }

    @Test func falseReturnRequiresOneMutationAndEventualCanonicalReadback() throws {
        var action = try Action(baseline: observation(), requested: 1)
        var calls = 0
        #expect(
            try !action.press(
                ready: true, observation: observation(),
                perform: {
                    calls += 1; return false
                },
                observe: { observation(binding: 1) }))
        #expect(action.actionReturned == false)
        #expect(try !action.complete(observation(binding: 1, value: 1)))
        #expect(try action.complete(observation(binding: 1, value: 1, mutations: 1)))
        #expect(calls == 1)
        #expect(throws: Action.Failure.self) {
            try action.press(
                ready: true, observation: observation(),
                perform: {
                    calls += 1; return true
                },
                observe: { observation(binding: 1, value: 1, mutations: 1) })
        }
        #expect(calls == 1)
    }

    @Test func trueReturnStillRequiresActualCompletion() throws {
        var action = try Action(baseline: observation(), requested: 1)
        #expect(
            try !action.press(
                ready: true, observation: observation(), perform: { true },
                observe: { observation(binding: 1) }))
        #expect(try action.complete(observation(binding: 1, value: 1, mutations: 1)))
    }

    @Test func missingReadinessNeverPressesAndChangedBaselineFails() throws {
        var action = try Action(baseline: observation(), requested: 1)
        var calls = 0
        #expect(
            try !action.press(
                ready: false, observation: observation(value: nil),
                perform: {
                    calls += 1; return false
                }, observe: { observation() }))
        for changed in [
            observation(binding: 1), observation(mutations: 1),
            observation(invariant: 8), observation(idle: false),
        ] {
            #expect(throws: Action.Failure.self) {
                try action.press(
                    ready: true, observation: changed,
                    perform: {
                        calls += 1; return true
                    },
                    observe: { observation(binding: 1, value: 1, mutations: 1) })
            }
        }
        #expect(calls == 0)
    }

    @Test func trueOrFalseWithoutEffectCannotBeRetried() throws {
        for returned in [true, false] {
            var action = try Action(baseline: observation(), requested: 1)
            var calls = 0
            for _ in 0..<2 {
                #expect(throws: Action.Failure.self) {
                    try action.press(
                        ready: true, observation: observation(),
                        perform: {
                            calls += 1; return returned
                        }, observe: { observation() })
                }
            }
            #expect(calls == 1)
        }
    }

    @Test func missingOrNoncanonicalReadbackNeverCompletes() throws {
        for value: Int? in [nil, -1, 2] {
            var action = try Action(baseline: observation(), requested: 1)
            #expect(throws: Action.Failure.self) {
                try action.press(
                    ready: true, observation: observation(), perform: { false },
                    observe: { observation(binding: 1, value: value, mutations: 1) })
            }
        }
        var action = try Action(baseline: observation(), requested: 1)
        #expect(
            try !action.press(
                ready: true, observation: observation(), perform: { false },
                observe: { observation(binding: 1, mutations: 1) }))
        #expect(try !action.complete(observation(binding: 1, mutations: 1)))
    }

    @Test func unrelatedMutationBusyStateBindingReversalAndDuplicateCallbackFail() throws {
        for changed in [
            observation(binding: 1, value: 1, mutations: 1, invariant: 8),
            observation(binding: 1, value: 1, mutations: 1, idle: false),
            observation(binding: 0, value: 1, mutations: 1),
            observation(binding: nil, value: 1, mutations: 1),
            observation(binding: 1, value: 1, mutations: 2),
        ] {
            var action = try Action(baseline: observation(), requested: 1)
            #expect(
                try !action.press(
                    ready: true, observation: observation(), perform: { false },
                    observe: { observation(binding: 1) }))
            #expect(throws: Action.Failure.self) { try action.complete(changed) }
        }
    }

    @Test func originalTrueFalseTrueJourneyUsesExactlyThreePresses() throws {
        var binding = 0
        var mutations = 0
        var calls = 0
        for requested in [1, 0, 1] {
            let initial = observation(binding: binding, value: binding, mutations: mutations)
            var action = try Action(baseline: initial, requested: requested)
            #expect(
                try action.press(
                    ready: true, observation: initial,
                    perform: {
                        calls += 1
                        binding = requested
                        mutations += 1
                        return false
                    },
                    observe: { observation(binding: binding, value: binding, mutations: mutations) }
                ))
        }
        #expect(calls == 3 && mutations == 3 && binding == 1)
    }
}
