import Foundation
#if SWIFT_PACKAGE
import FunctionalActionContract
#endif

enum FunctionalEvidenceAssembly {
    private typealias Evidence = FunctionalCollectedEvidence

    struct RequestFact {
        let ordinal: Int
        let sequence: Int
        let event: FunctionalCollectedEvidence.RequestEvent
        let token: String
        let operation: String
        let presentationID: String
        let payloadSHA256: String
        let responseSHA256: String?
        let caller: HostedFunctionalProcessIdentity
        let outcome: Bool?
        let activationID: String?
        let stepIndex: Int?
        let payload: Data?
    }

    struct StepFact {
        let index: Int
        let activationID: String
        let before: FunctionalCollectedEvidence.RawObservation
        let after: FunctionalCollectedEvidence.RawObservation
    }

    struct GenerationFacts {
        let capability: HostedFunctionalActionContext
        let presentationID: String
        let admission: FunctionalCollectedEvidence.AdmissionFacts
        let baseline: HostedFunctionalMutationJournal.Baseline
        let loadSequence: Int
        let recipeStepCount: Int
        let authoritativeReadPolicy: Data
        let events: [RequestFact]
        let steps: [StepFact]
        let authoritative: FunctionalCollectedEvidence.RawObservation
        let persistence: FunctionalCollectedEvidence.Persistence
        let rawBaseline: Data?
        let rawSaved: Data?
        let retired: [HostedFunctionalProcessIdentity]
        let drain: FunctionalCollectedEvidence.DrainFacts
        let colorPickerHistory: [FunctionalCollectedEvidence.ColorPickerHistoryFacts]
        let sealedThroughSequence: Int
    }

    private struct Progress {
        let start: RequestFact
        var next: Evidence.RequestEvent
        var response: RequestFact?
    }

    static func stage(
        facts: GenerationFacts, policy: FunctionalCollectedEvidence.Policy
    ) throws -> FunctionalCollectedEvidence.CompletedStage {
        let cap = facts.capability
        let definition = policy.definition
        let capabilityHash = FunctionalBytes.digest(try encode(cap))
        let binding = Evidence.Binding(
            sourceCommit: cap.sourceCommit, session: cap.session, owner: cap.owner,
            caseSHA256: cap.caseSHA256, phase: cap.phase, capabilitySHA256: capabilityHash,
            presentationID: facts.presentationID)
        guard definition.owner == cap.owner,
            FunctionalBytes.digest(try encode(definition)) == cap.caseSHA256,
            definition.activation.operation == cap.activationOperation,
            definition.operations == cap.operations,
            facts.admission.binding == binding, facts.drain.binding == binding,
            facts.admission.observedEngine == cap.engine, facts.admission.observedUI == cap.ui,
            FunctionalBytes.uuid(facts.presentationID), !facts.events.isEmpty,
            facts.events.count <= 4096, facts.recipeStepCount > 0, facts.recipeStepCount <= 16,
            !facts.steps.isEmpty, facts.steps.count <= facts.recipeStepCount,
            facts.steps.map(\.index) == facts.steps.map(\.index).sorted(),
            Set(facts.steps.map(\.index)).count == facts.steps.count,
            facts.steps.allSatisfy({ (0..<facts.recipeStepCount).contains($0.index) }),
            Set(facts.steps.map(\.activationID)).count == facts.steps.count,
            facts.steps.allSatisfy({ FunctionalBytes.uuid($0.activationID) })
        else { throw FunctionalFailure.invalid("actual generation assembly binding") }

        let selector = try FunctionalBytes.object(facts.authoritativeReadPolicy)
        try FunctionalBytes.exact(selector, ["schema", "owner", "operation", "payload"])
        guard try FunctionalBytes.integer(selector, "schema") == 1,
            selector["owner"] as? String == cap.owner,
            let readOperation = selector["operation"] as? String,
            cap.operations.contains(readOperation),
            let readPayload = selector["payload"] as? [String: Any]
        else {
            throw FunctionalFailure.invalid("compiled original readonly selector")
        }
        let readBytes = try FunctionalBytes.canonical(readPayload)
        var readonlyTokens = Set<String>()
        func isMutation(_ start: RequestFact) -> Bool {
            start.operation == cap.activationOperation && !readonlyTokens.contains(start.token)
        }
        var pending: [String: Progress] = [:]
        var admitted = Set<String>()
        var completed = Set<String>()
        var mutations: [(RequestFact, RequestFact)] = []
        var previousSequence = facts.baseline.sequence
        for (ordinal, event) in facts.events.enumerated() {
            guard event.ordinal == ordinal, safe(event.sequence),
                event.sequence > previousSequence, FunctionalBytes.uuid(event.token),
                event.presentationID == facts.presentationID,
                cap.operations.contains(event.operation),
                FunctionalBytes.hex(event.payloadSHA256, length: 64),
                event.activationID.map(FunctionalBytes.uuid) ?? true,
                event.stepIndex.map({ (0..<facts.recipeStepCount).contains($0) }) ?? true
            else { throw FunctionalFailure.invalid("actual globally ordered request fact") }
            previousSequence = event.sequence
            if event.event == .hostBefore {
                guard pending[event.token] == nil, !completed.contains(event.token),
                    pending.count < 8, event.caller == facts.admission.observedHost,
                    event.responseSHA256 == nil, event.outcome == nil
                else { throw FunctionalFailure.invalid("actual original request start") }
                if let payload = event.payload {
                    guard !payload.isEmpty, payload.count <= 1_048_576,
                        FunctionalBytes.digest(payload) == event.payloadSHA256
                    else { throw FunctionalFailure.invalid("original raw request payload") }
                }
                if event.operation == readOperation, let payload = event.payload,
                    let value = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                    try FunctionalBytes.canonical(value) == readBytes
                {
                    readonlyTokens.insert(event.token)
                }
                guard !isMutation(event) || event.sequence > facts.loadSequence else {
                    throw FunctionalFailure.invalid(
                        "original mutation before actual generation load")
                }
                pending[event.token] = Progress(start: event, next: .engineBefore)
                continue
            }
            guard var progress = pending[event.token], progress.next == event.event,
                event.operation == progress.start.operation,
                event.payloadSHA256 == progress.start.payloadSHA256, event.payload == nil,
                event.activationID == nil || event.activationID == progress.start.activationID,
                event.stepIndex == nil || event.stepIndex == progress.start.stepIndex,
                event.caller
                    == (event.event == .engineBefore || event.event == .engineAfter
                        ? cap.engine : facts.admission.observedHost)
            else { throw FunctionalFailure.invalid("actual five event request correlation") }
            if event.event == .engineBefore {
                guard event.responseSHA256 == nil, event.outcome == nil,
                    admitted.insert(event.token).inserted
                else { throw FunctionalFailure.invalid("actual engine admission") }
                progress.next = .engineAfter
            } else {
                guard event.outcome != nil,
                    event.outcome == true
                        ? event.responseSHA256.map({ FunctionalBytes.hex($0, length: 64) }) == true
                        : event.responseSHA256 == nil
                else { throw FunctionalFailure.invalid("actual original response result") }
                if event.event == .engineAfter {
                    progress.response = event
                    progress.next = .hostAfter
                } else {
                    guard let response = progress.response,
                        response.outcome == event.outcome,
                        response.responseSHA256 == event.responseSHA256
                    else { throw FunctionalFailure.invalid("unchanged actual original response") }
                    if event.event == .hostAfter {
                        progress.next = .nativeReply
                    } else {
                        if isMutation(progress.start) {
                            guard event.outcome == true else {
                                throw FunctionalFailure.invalid(
                                    "failed original activation mutation")
                            }
                            mutations.append((progress.start, event))
                        }
                        pending.removeValue(forKey: event.token)
                        completed.insert(event.token)
                        continue
                    }
                }
            }
            pending[event.token] = progress
        }
        guard Set(pending.keys).isSubset(of: admitted),
            !pending.values.contains(where: { isMutation($0.start) }),
            mutations.count == facts.steps.count
        else { throw FunctionalFailure.invalid("complete original activation steps") }
        try requireDrain(facts.drain, admitted: admitted, pending: Set(pending.keys))

        var records: [[String: Any]] = []
        var rawMutations: [Evidence.RawMutation] = []
        var sequence = facts.loadSequence
        for (index, mutation) in mutations.enumerated() {
            let (start, reply) = mutation
            let step = facts.steps[index]
            guard start.stepIndex == step.index, start.activationID == step.activationID,
                let payload = start.payload, let responseHash = reply.responseSHA256,
                safe(step.before.sequence), safe(step.after.sequence),
                sequence < step.before.sequence, step.before.sequence < start.sequence,
                reply.sequence < step.after.sequence,
                FunctionalBytes.uuid(step.before.observationID),
                FunctionalBytes.uuid(step.after.observationID),
                !step.before.bytes.isEmpty, !step.after.bytes.isEmpty,
                step.before.bytes.count <= 1_048_576, step.after.bytes.count <= 1_048_576
            else { throw FunctionalFailure.invalid("independent original mutation step reads") }
            sequence = step.after.sequence
            let request: [String: Any] = [
                "schema": 1, "sourceCommit": cap.sourceCommit, "session": cap.session,
                "owner": cap.owner, "phase": cap.phase, "capabilitySHA256": capabilityHash,
                "requestID": start.token, "operation": start.operation,
                "payloadSHA256": start.payloadSHA256,
            ]
            records.append([
                "request": request, "activationID": step.activationID,
                "origin": "authenticated-original-control",
                "ui": try object(cap.ui), "engine": try object(cap.engine),
                "payload": payload.base64EncodedString(), "sendSequence": start.sequence,
                "acknowledgement": [
                    "request": request, "engine": try object(cap.engine),
                    "success": reply.outcome!, "responseSHA256": responseHash,
                    "sequence": reply.sequence,
                ],
                "transition": [
                    "kind": definition.activation.mutation.kind,
                    "reader": "independent-hosted-producer",
                    "capabilitySHA256": capabilityHash, "requestID": start.token,
                    "before": observation(step.before), "after": observation(step.after),
                ],
            ])
            rawMutations.append(
                .init(requestID: start.token, before: step.before, after: step.after))
        }
        let journalObject: [String: Any] = [
            "schema": 1, "sourceCommit": cap.sourceCommit, "session": cap.session,
            "owner": cap.owner, "phase": cap.phase, "capabilitySHA256": capabilityHash,
            "presentationID": facts.presentationID, "baseline": try object(facts.baseline),
            "loadSequence": facts.loadSequence, "records": records,
            "sealedThroughSequence": facts.sealedThroughSequence,
        ]
        let journal = try JSONDecoder().decode(
            HostedFunctionalMutationJournal.self, from: FunctionalBytes.canonical(journalObject))
        _ = try journal.validate(
            context: cap, capabilitySHA256: capabilityHash,
            presentationID: facts.presentationID,
            persistenceApplicable: definition.persistence.applicable,
            mutationKind: definition.activation.mutation.kind,
            payloadKeys: definition.activation.mutation.payloadKeys,
            selectedRequestID: mutations.last!.0.token,
            persistenceSequence: facts.persistence.sequence)
        return Evidence.CompletedStage(
            capability: cap, presentationID: facts.presentationID,
            admission: facts.admission, journal: journal,
            requestRecords: facts.events.map {
                .init(
                    ordinal: $0.ordinal, event: $0.event, token: $0.token,
                    operation: $0.operation, presentationID: $0.presentationID,
                    payloadSHA256: $0.payloadSHA256, responseSHA256: $0.responseSHA256,
                    caller: $0.caller, outcome: $0.outcome)
            }, rawMutations: rawMutations, colorPickerHistory: facts.colorPickerHistory,
            authoritative: facts.authoritative, persistence: facts.persistence,
            rawBaseline: facts.rawBaseline, rawSaved: facts.rawSaved,
            retired: facts.retired, drain: facts.drain)
    }

    private static func requireDrain(
        _ drain: Evidence.DrainFacts, admitted: Set<String>, pending: Set<String>
    ) throws {
        let cancelled = Set(drain.cancelledRequestTokens)
        let requested = Set(drain.retirementRequestedTokens)
        let joined = Set(drain.joinedRequestTokens)
        guard cancelled.count == drain.cancelledRequestTokens.count,
            requested.count == drain.retirementRequestedTokens.count,
            joined.count == drain.joinedRequestTokens.count,
            cancelled.isSubset(of: admitted), requested.isSubset(of: admitted),
            joined == pending.union(cancelled).union(requested),
            Set(drain.capturedLeaseTokens).count == drain.capturedLeaseTokens.count,
            Set(drain.releasedLeaseTokens).count == drain.releasedLeaseTokens.count,
            Set(drain.capturedLeaseTokens) == Set(drain.releasedLeaseTokens)
        else { throw FunctionalFailure.invalid("actual request joins and lease sets") }
    }

    private static func observation(_ raw: Evidence.RawObservation) -> [String: Any] {
        let hash = FunctionalBytes.digest(raw.bytes)
        return [
            "observationID": raw.observationID, "sequence": raw.sequence,
            "observationSHA256": hash, "expectedSHA256": hash,
        ]
    }

    private static func safe(_ value: Int) -> Bool {
        value > 0 && value <= 9_007_199_254_740_991
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try FunctionalBytes.object(encode(value))
    }
}
