import Foundation
import FunctionalActionContract
import Testing
@testable import FunctionalProducerModels

struct FunctionalEvidenceAssemblyTests {
    private typealias Evidence = FunctionalCollectedEvidence
    private typealias Assembly = FunctionalEvidenceAssembly
    private let source = String(repeating: "a", count: 40)
    private let session = "00000000-0000-4000-8000-000000000001"

    private func id(_ number: Int) -> String {
        "00000000-0000-4000-8000-" + String(format: "%012d", number)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ value: [String: Any], as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: FunctionalBytes.canonical(value))
    }

    private var policy: Evidence.Policy {
        let before: Evidence.SemanticValue = .object(["enabled": .boolean(false)])
        let after: Evidence.SemanticValue = .object(["enabled": .boolean(true)])
        return .init(
            definition: .init(
                schema: 1, owner: "keepAwake",
                activation: .init(
                    kind: "native-accessibility", control: "Toggle awake",
                    operation: "keepAwake.set",
                    sources: [
                        .init(
                            path: "Extensions/keepAwake/Test.swift",
                            sha256: String(repeating: "b", count: 64))
                    ],
                    mutation: .init(kind: "state-transition", payloadKeys: ["enabled"])),
                operations: ["keepAwake.set", "keepAwake.read"],
                observation: .init(kind: "checked-engine-readback", name: "awake-state"),
                persistence: .init(applicable: true, name: "awake-preference"),
                limits: ["synthetic-platform-adapter"]),
            semantics: ["initial", "updated", "reinstalled"].enumerated().map { index, phase in
                .init(
                    phase: phase, before: .literal(before), after: .literal(after),
                    savedBefore: index == 0 ? before : after, savedAfter: after, relation: nil)
            })
    }

    private struct Capture {
        let cap: HostedFunctionalActionContext
        let host: HostedFunctionalProcessIdentity
        let admission: Evidence.AdmissionFacts
        let baseline: HostedFunctionalMutationJournal.Baseline
        var loadSequence = 2
        var sealedThroughSequence = 13
        var recipeStepCount = 1
        var authoritativeReadPolicy = Data(
            "{\"operation\":\"keepAwake.read\",\"owner\":\"keepAwake\",\"payload\":{},\"schema\":1}"
                .utf8)
        var events: [Assembly.RequestFact]
        var steps: [Assembly.StepFact]
        var authoritative: Evidence.RawObservation
        var persistence: Evidence.Persistence
        var rawBaseline: Data?
        var rawSaved: Data?
        var drain: Evidence.DrainFacts

        var facts: Assembly.GenerationFacts {
            .init(
                capability: cap, presentationID: admission.binding.presentationID,
                admission: admission, baseline: baseline, loadSequence: loadSequence,
                recipeStepCount: recipeStepCount, authoritativeReadPolicy: authoritativeReadPolicy,
                events: events, steps: steps, authoritative: authoritative,
                persistence: persistence, rawBaseline: rawBaseline, rawSaved: rawSaved,
                retired: [], drain: drain, colorPickerHistory: [],
                sealedThroughSequence: sealedThroughSequence)
        }
    }

    private func capture() throws -> Capture {
        func process(_ pid: Int) -> [String: Any] {
            [
                "pid": pid, "birthSeconds": 1000 + pid, "birthMicroseconds": 10, "uid": 501,
                "executableSHA256": String(repeating: "b", count: 64),
            ]
        }
        let root = "/synthetic/functional-fixture-" + session
        let cap = try decode(
            [
                "schema": 1, "sourceCommit": source, "session": session, "owner": "keepAwake",
                "uid": 501, "fixtureRoot": root,
                "hostIdentifier": "com.pulkit.edith.tests.worker-" + session,
                "home": root + "/keepAwake-home", "dataDirectory": root + "/data/keepAwake",
                "hostABI": "edith-host-2",
                "caseSHA256": FunctionalBytes.digest(try encode(policy.definition)),
                "activationOperation": "keepAwake.set", "phase": "initial",
                "pairScope": "synthetic-development", "previousVersion": "1.0.0",
                "currentVersion": "1.1.0", "version": "1.0.0",
                "packageSHA256": String(repeating: "c", count: 64), "engine": process(100),
                "ui": process(101), "operations": policy.definition.operations, "ownedPaths": [],
            ], as: HostedFunctionalActionContext.self)
        let host = try decode(process(900), as: HostedFunctionalProcessIdentity.self)
        let binding = Evidence.Binding(
            sourceCommit: source, session: session, owner: "keepAwake",
            caseSHA256: cap.caseSHA256, phase: "initial",
            capabilitySHA256: FunctionalBytes.digest(try encode(cap)), presentationID: id(90))
        let admission = Evidence.AdmissionFacts(
            binding: binding, observedHost: host,
            observedEngine: cap.engine, observedUI: cap.ui,
            admission: .init(
                heldRootPinned: true, heldDescriptorPinned: true,
                sourceClean: true, sourcePinned: true, payloadSignatureVerified: true,
                architectureVerified: true, hostABIVerified: true, originalFactoryUnchanged: true,
                originalControlsUnchanged: true, staleGenerationRejected: true))
        let before = Data("{\"enabled\":false}".utf8)
        let after = Data("{\"enabled\":true}".utf8)
        let beforeHash = FunctionalBytes.digest(before)
        let afterHash = FunctionalBytes.digest(after)
        let baseline = try decode(
            [
                "reader": "independent-hosted-producer", "observationID": id(22),
                "sequence": 1, "readbackSHA256": beforeHash, "expectedSHA256": beforeHash,
            ],
            as: HostedFunctionalMutationJournal.Baseline.self)
        let events: [Assembly.RequestFact] = [
            Evidence.RequestEvent.hostBefore, .engineBefore,
            .engineAfter, .hostAfter, .nativeReply,
        ].enumerated().map { ordinal, event in
            .init(
                ordinal: ordinal, sequence: 4 + ordinal, event: event, token: id(10),
                operation: "keepAwake.set", presentationID: id(90), payloadSHA256: afterHash,
                responseSHA256: ordinal < 2 ? nil : afterHash,
                caller: ordinal == 1 || ordinal == 2 ? cap.engine : host,
                outcome: ordinal < 2 ? nil : true, activationID: id(11), stepIndex: 0,
                payload: ordinal == 0 ? after : nil)
        }
        let drain = Evidence.DrainFacts(
            binding: binding, stopPreparationToken: id(50),
            engineStop: .init(
                stop: .init(
                    requestID: id(30), responseToken: id(30),
                    operation: "stop", outcome: true),
                preparation: .init(
                    requestID: id(32), responseToken: id(32),
                    operation: "prepareDisable", outcome: true),
                worker: cap.engine, observedBirths: [], absentBirths: [],
                terminationStatus: 0, terminationReason: 1, signalAttempts: [], sequence: 14),
            nativeStop: .init(
                stop: .init(
                    requestID: id(50), responseToken: id(50),
                    operation: "stop", outcome: true), ui: cap.ui, engine: cap.engine,
                observedBirths: [], absentBirths: [], signalAttempts: [],
                joinedTasks: ["engine-receivers"], invalidations: [], sequence: 15),
            captured: [cap.engine, cap.ui], absent: [cap.engine, cap.ui],
            cancelledRequestTokens: [], retirementRequestedTokens: [], joinedRequestTokens: [],
            capturedLeaseTokens: [id(40)], releasedLeaseTokens: [id(40)], cleanupStarted: false)
        return Capture(
            cap: cap, host: host, admission: admission, baseline: baseline,
            events: events,
            steps: [
                .init(
                    index: 0, activationID: id(11),
                    before: .init(observationID: id(20), sequence: 3, bytes: before),
                    after: .init(observationID: id(21), sequence: 9, bytes: after))
            ],
            authoritative: .init(observationID: id(23), sequence: 10, bytes: after),
            persistence: .init(
                name: "awake-preference", readbackSHA256: afterHash,
                expectedSHA256: afterHash, beforeActivation: nil, sequence: 11),
            rawBaseline: before, rawSaved: after, drain: drain)
    }

    private func event(
        _ original: Assembly.RequestFact, ordinal: Int? = nil, sequence: Int? = nil,
        caller: HostedFunctionalProcessIdentity? = nil, activationID: String? = nil,
        stepIndex: Int? = nil, payload: Data? = nil
    ) -> Assembly.RequestFact {
        .init(
            ordinal: ordinal ?? original.ordinal, sequence: sequence ?? original.sequence,
            event: original.event, token: original.token, operation: original.operation,
            presentationID: original.presentationID, payloadSHA256: original.payloadSHA256,
            responseSHA256: original.responseSHA256, caller: caller ?? original.caller,
            outcome: original.outcome, activationID: activationID ?? original.activationID,
            stepIndex: stepIndex ?? original.stepIndex, payload: payload ?? original.payload)
    }

    private func drain(
        _ original: Evidence.DrainFacts, cancelled: [String] = [],
        requested: [String] = [], joined: [String] = [], released: [String]? = nil
    ) -> Evidence.DrainFacts {
        .init(
            binding: original.binding, stopPreparationToken: original.stopPreparationToken,
            engineStop: original.engineStop, nativeStop: original.nativeStop,
            captured: original.captured, absent: original.absent,
            cancelledRequestTokens: cancelled, retirementRequestedTokens: requested,
            joinedRequestTokens: joined, capturedLeaseTokens: original.capturedLeaseTokens,
            releasedLeaseTokens: released ?? original.releasedLeaseTokens,
            cleanupStarted: original.cleanupStarted)
    }

    @Test func preservesActualBytesAndFullCompletionSequence() throws {
        let captured = try capture()
        let stage = try Assembly.stage(facts: captured.facts, policy: policy)
        #expect(stage.journal.records[0].acknowledgement.sequence == captured.events[4].sequence)
        #expect(stage.journal.records[0].sendSequence == captured.events[0].sequence)
        #expect(
            stage.journal.records[0].payload == captured.events[0].payload!.base64EncodedString())
        #expect(stage.rawMutations[0].before.bytes == captured.steps[0].before.bytes)
        #expect(stage.rawMutations[0].after.bytes == captured.steps[0].after.bytes)
        #expect(stage.rawBaseline == captured.rawBaseline && stage.rawSaved == captured.rawSaved)
        #expect(stage.requestRecords.map(\.event) == captured.events.map(\.event))
        #expect(stage.drain.joinedRequestTokens.isEmpty)
        let collector = try Evidence(
            sourceCommit: source, session: session, owner: "keepAwake",
            uid: 501, compiledPolicy: policy)
        try collector.appendStage(stage)
    }

    @Test func rejectsGlobalSequenceAndReceiverChanges() throws {
        for index in 0..<5 {
            var captured = try capture()
            captured.events[index] = event(captured.events[index], sequence: 2)
            #expect(throws: (any Error).self) {
                try Assembly.stage(facts: captured.facts, policy: policy)
            }
        }
        var captured = try capture()
        captured.events[2] = event(captured.events[2], caller: captured.host)
        #expect(throws: (any Error).self) {
            try Assembly.stage(facts: captured.facts, policy: policy)
        }
    }

    @Test func rejectsMissingCompletionAndChangedAuthorization() throws {
        for index in 0..<5 {
            var captured = try capture()
            captured.events.remove(at: index)
            captured.events = captured.events.enumerated().map {
                event($0.element, ordinal: $0.offset)
            }
            #expect(throws: (any Error).self) {
                try Assembly.stage(facts: captured.facts, policy: policy)
            }
        }
        var captured = try capture()
        captured.events[4] = event(captured.events[4], activationID: id(99))
        #expect(throws: (any Error).self) {
            try Assembly.stage(facts: captured.facts, policy: policy)
        }
    }

    @Test func rejectsPayloadSubstitutionAndPrematureProviderRead() throws {
        var captured = try capture()
        captured.events[0] = event(captured.events[0], payload: Data("{\"enabled\":false}".utf8))
        #expect(throws: (any Error).self) {
            try Assembly.stage(facts: captured.facts, policy: policy)
        }
        captured = try capture()
        let step = captured.steps[0]
        captured.steps[0] = .init(
            index: 0, activationID: step.activationID, before: step.before,
            after: .init(
                observationID: step.after.observationID, sequence: 7, bytes: step.after.bytes))
        #expect(throws: (any Error).self) {
            try Assembly.stage(facts: captured.facts, policy: policy)
        }
    }

    @Test func rejectsExtraMutationWithoutIndependentStep() throws {
        var captured = try capture()
        captured.events += captured.events.enumerated().map { index, original in
            .init(
                ordinal: index + 5, sequence: index + 9, event: original.event, token: id(12),
                operation: original.operation, presentationID: original.presentationID,
                payloadSHA256: original.payloadSHA256, responseSHA256: original.responseSHA256,
                caller: original.caller, outcome: original.outcome,
                activationID: original.activationID, stepIndex: 0, payload: original.payload)
        }
        #expect(throws: (any Error).self) {
            try Assembly.stage(facts: captured.facts, policy: policy)
        }
    }

    @Test func preservesIndependentCancellationAndRequestedJoins() throws {
        for requested in [false, true] {
            var captured = try capture()
            captured.drain = drain(
                captured.drain, cancelled: requested ? [] : [id(10)],
                requested: requested ? [id(10)] : [], joined: [id(10)])
            let stage = try Assembly.stage(facts: captured.facts, policy: policy)
            #expect(stage.drain.joinedRequestTokens == [id(10)])
            #expect(stage.drain.cancelledRequestTokens == captured.drain.cancelledRequestTokens)
            #expect(
                stage.drain.retirementRequestedTokens == captured.drain.retirementRequestedTokens)
        }
    }

    @Test func rejectsInventedJoinsAndMissingRetirementOrLeaseFacts() throws {
        for scenario in 0..<5 {
            var captured = try capture()
            switch scenario {
            case 0: captured.drain = drain(captured.drain, joined: [id(10)])
            case 1: captured.drain = drain(captured.drain, cancelled: [id(10)])
            case 2: captured.drain = drain(captured.drain, requested: [id(99)], joined: [id(99)])
            case 3:
                captured.drain = drain(
                    captured.drain, requested: [id(10), id(10)], joined: [id(10)])
            default: captured.drain = drain(captured.drain, released: [])
            }
            #expect(throws: (any Error).self) {
                try Assembly.stage(facts: captured.facts, policy: policy)
            }
        }
    }

    @Test func collectorStillRejectsWrongRawSavedBytes() throws {
        var captured = try capture()
        captured.rawSaved = Data("{\"enabled\":false}".utf8)
        let stage = try Assembly.stage(facts: captured.facts, policy: policy)
        #expect(stage.rawSaved == captured.rawSaved)
        let collector = try Evidence(
            sourceCommit: source, session: session, owner: "keepAwake",
            uid: 501, compiledPolicy: policy)
        #expect(throws: (any Error).self) { try collector.appendStage(stage) }
    }

    @Test func preservesSparseOriginalRecipeStepIndexes() throws {
        var captured = try capture()
        captured.recipeStepCount = 3
        captured.events = captured.events.map { event($0, stepIndex: 2) }
        let original = captured.steps[0]
        captured.steps = [
            .init(
                index: 2, activationID: original.activationID,
                before: original.before, after: original.after)
        ]
        let stage = try Assembly.stage(facts: captured.facts, policy: policy)
        #expect(stage.journal.records.count == 1)
        #expect(stage.journal.records[0].sendSequence == captured.events[0].sequence)
        let collector = try Evidence(
            sourceCommit: source, session: session, owner: "keepAwake",
            uid: 501, compiledPolicy: policy)
        try collector.appendStage(stage)
    }

    @Test func rejectsIndexesOutsideCompiledRecipeAndDuplicateMutationSteps() throws {
        for recipeStepCount in [0, 17] {
            var captured = try capture()
            captured.recipeStepCount = recipeStepCount
            #expect(throws: (any Error).self) {
                try Assembly.stage(facts: captured.facts, policy: policy)
            }
        }
        for index in [-1, 3] {
            var captured = try capture()
            captured.recipeStepCount = 3
            captured.events = captured.events.map { event($0, stepIndex: index) }
            let step = captured.steps[0]
            captured.steps = [
                .init(
                    index: index, activationID: step.activationID,
                    before: step.before, after: step.after)
            ]
            #expect(throws: (any Error).self) {
                try Assembly.stage(facts: captured.facts, policy: policy)
            }
        }
        var captured = try capture()
        captured.recipeStepCount = 3
        captured.steps.append(captured.steps[0])
        #expect(throws: (any Error).self) {
            try Assembly.stage(facts: captured.facts, policy: policy)
        }
    }

    @Test func preservesSameOperationReadonlyStartupWithoutMutationOrActor() throws {
        var captured = try capture()
        captured.authoritativeReadPolicy = try FunctionalBytes.canonical(
            JSONSerialization.jsonObject(
                with: Data(
                    "{\"schema\":1,\"owner\":\"keepAwake\",\"operation\":\"keepAwake.set\",\"payload\":{\"readOnly\":true,\"value\":null}}"
                        .utf8)))
        let readonly = Data("{\"value\":null,\"readOnly\":true}".utf8)
        let digest = FunctionalBytes.digest(readonly)
        let startup = captured.events.enumerated().map { ordinal, event in
            Assembly.RequestFact(
                ordinal: ordinal, sequence: ordinal + 3, event: event.event,
                token: id(88), operation: event.operation, presentationID: event.presentationID,
                payloadSHA256: digest, responseSHA256: ordinal < 2 ? nil : event.responseSHA256,
                caller: event.caller, outcome: event.outcome, activationID: nil, stepIndex: nil,
                payload: ordinal == 0 ? readonly : nil)
        }
        captured.events =
            startup
            + captured.events.enumerated().map { ordinal, original in
                event(original, ordinal: ordinal + 5, sequence: original.sequence + 6)
            }
        captured.loadSequence = 8
        captured.sealedThroughSequence = 19
        let step = captured.steps[0]
        captured.steps = [
            .init(
                index: step.index, activationID: step.activationID,
                before: .init(
                    observationID: step.before.observationID, sequence: 9, bytes: step.before.bytes),
                after: .init(
                    observationID: step.after.observationID, sequence: 15, bytes: step.after.bytes))
        ]
        captured.authoritative = .init(
            observationID: captured.authoritative.observationID, sequence: 16,
            bytes: captured.authoritative.bytes)
        captured.persistence = .init(
            name: captured.persistence.name, readbackSHA256: captured.persistence.readbackSHA256,
            expectedSHA256: captured.persistence.expectedSHA256, beforeActivation: nil, sequence: 17
        )
        let old = captured.drain
        let engine = old.engineStop
        let native = old.nativeStop
        captured.drain = .init(
            binding: old.binding, stopPreparationToken: old.stopPreparationToken,
            engineStop: .init(
                stop: engine.stop, preparation: engine.preparation, worker: engine.worker,
                observedBirths: engine.observedBirths, absentBirths: engine.absentBirths,
                terminationStatus: engine.terminationStatus,
                terminationReason: engine.terminationReason,
                signalAttempts: engine.signalAttempts, sequence: 20),
            nativeStop: .init(
                stop: native.stop, ui: native.ui, engine: native.engine,
                observedBirths: native.observedBirths, absentBirths: native.absentBirths,
                signalAttempts: native.signalAttempts, joinedTasks: native.joinedTasks,
                invalidations: native.invalidations, sequence: 21),
            captured: old.captured, absent: old.absent, cancelledRequestTokens: [],
            retirementRequestedTokens: [], joinedRequestTokens: [],
            capturedLeaseTokens: old.capturedLeaseTokens,
            releasedLeaseTokens: old.releasedLeaseTokens, cleanupStarted: false)
        let stage = try Assembly.stage(facts: captured.facts, policy: policy)
        let collector = try Evidence(
            sourceCommit: source, session: session, owner: "keepAwake",
            uid: 501, compiledPolicy: policy)
        try collector.appendStage(stage)
        #expect(stage.requestRecords.count == 10)
        #expect(stage.journal.records.count == 1)
        #expect(stage.journal.records[0].request.requestID != id(88))
        #expect(stage.journal.records[0].sendSequence == 10)
    }

    @Test func rejectsUnboundReadonlySelectorAndMutationBeforeLoad() throws {
        var captured = try capture()
        captured.authoritativeReadPolicy = try FunctionalBytes.canonical(
            JSONSerialization.jsonObject(
                with: Data(
                    "{\"schema\":1,\"owner\":\"system\",\"operation\":\"keepAwake.read\",\"payload\":{}}"
                        .utf8)))
        #expect(throws: (any Error).self) {
            try Assembly.stage(facts: captured.facts, policy: policy)
        }
        captured = try capture()
        captured.loadSequence = 5
        #expect(throws: (any Error).self) {
            try Assembly.stage(facts: captured.facts, policy: policy)
        }
        captured = try capture()
        captured.authoritativeReadPolicy = try FunctionalBytes.canonical(
            JSONSerialization.jsonObject(
                with: Data(
                    "{\"schema\":1,\"owner\":\"keepAwake\",\"operation\":\"keepAwake.set\",\"payload\":{\"enabled\":false}}"
                        .utf8)))
        let stage = try Assembly.stage(facts: captured.facts, policy: policy)
        #expect(stage.journal.records.count == 1)
    }
}
