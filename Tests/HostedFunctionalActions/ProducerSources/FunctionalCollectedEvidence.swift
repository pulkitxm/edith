import CoreFoundation
import Foundation
#if SWIFT_PACKAGE
import FunctionalActionContract
#endif

final class FunctionalCollectedEvidence {
    struct SourcePin: Codable, Equatable {
        let path: String
        let sha256: String
    }

    struct Mutation: Codable, Equatable {
        let kind: String
        let payloadKeys: [String]
    }

    struct ActivationPolicy: Codable, Equatable {
        let kind: String
        let control: String
        let operation: String
        let sources: [SourcePin]
        let mutation: Mutation
    }

    struct ObservationPolicy: Codable, Equatable {
        let kind: String
        let name: String
    }

    struct PersistencePolicy: Codable, Equatable {
        let applicable: Bool
        let name: String
    }

    struct Definition: Codable, Equatable {
        let schema: Int
        let owner: String
        let activation: ActivationPolicy
        let operations: [String]
        let observation: ObservationPolicy
        let persistence: PersistencePolicy
        let limits: [String]
    }

    indirect enum SemanticValue: Encodable, Equatable {
        case null
        case boolean(Bool)
        case integer(Int)
        case number(Double)
        case string(String)
        case array([SemanticValue])
        case object([String: SemanticValue])

        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .null: try value.encodeNil()
            case .boolean(let item): try value.encode(item)
            case .integer(let item): try value.encode(item)
            case .number(let item): try value.encode(item)
            case .string(let item): try value.encode(item)
            case .array(let item): try value.encode(item)
            case .object(let item): try value.encode(item)
            }
        }
    }

    indirect enum SemanticRule: Equatable {
        case literal(SemanticValue)
        case integer(minimum: Int, maximum: Int)
        case number(minimum: Double, maximum: Double)
        case object([String: SemanticRule])
        case array(minimumCount: Int, maximumCount: Int, element: SemanticRule)
        case oneOf([SemanticValue])
        case sha256
        case uuid
        case nullable(SemanticRule)

        fileprivate func requireCompiled(depth: Int = 0) throws {
            guard depth < 32 else {
                throw FunctionalFailure.invalid("bounded source semantic depth")
            }
            switch self {
            case .literal(let value):
                guard try FunctionalCollectedEvidence.encode(value).count <= 1_048_576 else {
                    throw FunctionalFailure.invalid("bounded source semantic literal")
                }
            case .integer(let minimum, let maximum):
                guard minimum <= maximum else {
                    throw FunctionalFailure.invalid("source integer interval")
                }
            case .number(let minimum, let maximum):
                guard minimum.isFinite, maximum.isFinite, minimum <= maximum else {
                    throw FunctionalFailure.invalid("source finite numeric interval")
                }
            case .object(let fields):
                guard fields.count <= 128, fields.keys.allSatisfy(FunctionalCollectedEvidence.text)
                else {
                    throw FunctionalFailure.invalid("source exact semantic fields")
                }
                for rule in fields.values { try rule.requireCompiled(depth: depth + 1) }
            case .array(let minimum, let maximum, let element):
                guard minimum >= 0, maximum >= minimum, maximum <= 65_536 else {
                    throw FunctionalFailure.invalid("source bounded semantic array")
                }
                try element.requireCompiled(depth: depth + 1)
            case .oneOf(let values):
                guard !values.isEmpty, values.count <= 32 else {
                    throw FunctionalFailure.invalid("source finite semantic alternatives")
                }
                for value in values {
                    try SemanticRule.literal(value).requireCompiled(depth: depth + 1)
                }
            case .sha256, .uuid: break
            case .nullable(let rule): try rule.requireCompiled(depth: depth + 1)
            }
        }

        fileprivate func matches(_ value: Any) throws -> Bool {
            switch self {
            case .literal(let expected):
                return try FunctionalBytes.canonical(value)
                    == FunctionalCollectedEvidence.encode(expected)
            case .integer(let minimum, let maximum):
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                    let integer = Int(exactly: number.doubleValue)
                else { return false }
                return (minimum...maximum).contains(integer)
            case .number(let minimum, let maximum):
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                    number.doubleValue.isFinite
                else { return false }
                return (minimum...maximum).contains(number.doubleValue)
            case .object(let rules):
                guard let object = value as? [String: Any], Set(object.keys) == Set(rules.keys)
                else { return false }
                for (name, rule) in rules { if try !rule.matches(object[name]!) { return false } }
                return true
            case .array(let minimum, let maximum, let element):
                guard let values = value as? [Any], (minimum...maximum).contains(values.count)
                else { return false }
                for value in values { if try !element.matches(value) { return false } }
                return true
            case .oneOf(let expected):
                let bytes = try FunctionalBytes.canonical(value)
                return try expected.contains { try FunctionalCollectedEvidence.encode($0) == bytes }
            case .sha256:
                return (value as? String).map { FunctionalBytes.hex($0, length: 64) } ?? false
            case .uuid:
                return (value as? String).map(FunctionalBytes.uuid) ?? false
            case .nullable(let rule):
                return value is NSNull ? true : try rule.matches(value)
            }
        }
    }

    enum Relation {
        case colorPickerHistory
    }

    struct PhaseSemantics {
        let phase: String
        let before: SemanticRule
        let after: SemanticRule
        let savedBefore: SemanticValue?
        let savedAfter: SemanticValue?
        let relation: Relation?
    }

    struct Policy {
        let definition: Definition
        let semantics: [PhaseSemantics]
    }

    struct Binding: Equatable {
        let sourceCommit: String
        let session: String
        let owner: String
        let caseSHA256: String
        let phase: String
        let capabilitySHA256: String
        let presentationID: String
    }

    struct Admission: Encodable {
        let heldRootPinned: Bool
        let heldDescriptorPinned: Bool
        let sourceClean: Bool
        let sourcePinned: Bool
        let payloadSignatureVerified: Bool
        let architectureVerified: Bool
        let hostABIVerified: Bool
        let originalFactoryUnchanged: Bool
        let originalControlsUnchanged: Bool
        let staleGenerationRejected: Bool

        var complete: Bool {
            heldRootPinned && heldDescriptorPinned && sourceClean && sourcePinned
                && payloadSignatureVerified && architectureVerified && hostABIVerified
                && originalFactoryUnchanged && originalControlsUnchanged && staleGenerationRejected
        }
    }

    struct AdmissionFacts {
        let binding: Binding
        let observedHost: HostedFunctionalProcessIdentity
        let observedEngine: HostedFunctionalProcessIdentity
        let observedUI: HostedFunctionalProcessIdentity
        let admission: Admission
    }

    enum RequestEvent: String {
        case hostBefore = "before-original-request"
        case engineBefore = "before-engine-receiver"
        case engineAfter = "after-engine-receiver"
        case hostAfter = "after-original-response"
        case nativeReply = "native-emitted-reply"
    }

    struct RequestRecord {
        let ordinal: Int
        let event: RequestEvent
        let token: String
        let operation: String
        let presentationID: String
        let payloadSHA256: String
        let responseSHA256: String?
        let caller: HostedFunctionalProcessIdentity
        let outcome: Bool?
    }

    struct RawObservation {
        let observationID: String
        let sequence: Int
        let bytes: Data
    }

    struct RawMutation {
        let requestID: String
        let before: RawObservation
        let after: RawObservation
    }

    struct PriorPersistence: Encodable {
        let reader: String
        let observationID: String
        let capabilitySHA256: String
        let engine: HostedFunctionalProcessIdentity
        let ui: HostedFunctionalProcessIdentity
        let beforeRequestID: String
        let sequence: Int
        let readbackSHA256: String
        let expectedSHA256: String
    }

    struct Persistence: Encodable {
        let name: String
        let readbackSHA256: String?
        let expectedSHA256: String?
        let beforeActivation: PriorPersistence?
        let sequence: Int

        enum CodingKeys: CodingKey {
            case name, readbackSHA256, expectedSHA256, beforeActivation, sequence
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(name, forKey: .name)
            try values.encode(readbackSHA256, forKey: .readbackSHA256)
            try values.encode(expectedSHA256, forKey: .expectedSHA256)
            try values.encode(beforeActivation, forKey: .beforeActivation)
            try values.encode(sequence, forKey: .sequence)
        }
    }

    struct CapturedBirth: Equatable, Hashable {
        let pid: Int32
        let birthSeconds: Int64
        let birthMicroseconds: Int32
    }

    struct StopAcknowledgement {
        let requestID: String
        let responseToken: String
        let operation: String
        let outcome: Bool
    }

    struct EngineStopReceipt {
        let stop: StopAcknowledgement
        let preparation: StopAcknowledgement
        let worker: HostedFunctionalProcessIdentity
        let observedBirths: [CapturedBirth]
        let absentBirths: [CapturedBirth]
        let terminationStatus: Int
        let terminationReason: Int
        let signalAttempts: [Int]
        let sequence: Int
    }

    struct Invalidation {
        let site: String
        let peer: HostedFunctionalProcessIdentity?
        let peerWasRunning: Bool?
    }

    struct NativeStopReceipt {
        let stop: StopAcknowledgement
        let ui: HostedFunctionalProcessIdentity
        let engine: HostedFunctionalProcessIdentity
        let observedBirths: [CapturedBirth]
        let absentBirths: [CapturedBirth]
        let signalAttempts: [Int]
        let joinedTasks: [String]
        let invalidations: [Invalidation]
        let sequence: Int
    }

    struct DrainFacts {
        let binding: Binding
        let stopPreparationToken: String
        let engineStop: EngineStopReceipt
        let nativeStop: NativeStopReceipt
        let captured: [HostedFunctionalProcessIdentity]
        let absent: [HostedFunctionalProcessIdentity]
        let cancelledRequestTokens: [String]
        let retirementRequestedTokens: [String]
        let joinedRequestTokens: [String]
        let capturedLeaseTokens: [String]
        let releasedLeaseTokens: [String]
        let cleanupStarted: Bool
    }

    struct ColorPickerHistoryFacts {
        let binding: Binding
        let requestID: String
        let providerBeforePreferences: Data
        let providerAfterPreferences: Data
        let rawBeforePreferences: Data
        let rawAfterPreferences: Data
    }

    struct CompletedStage {
        let capability: HostedFunctionalActionContext
        let presentationID: String
        let admission: AdmissionFacts
        let journal: HostedFunctionalMutationJournal
        let requestRecords: [RequestRecord]
        let rawMutations: [RawMutation]
        let colorPickerHistory: [ColorPickerHistoryFacts]
        let authoritative: RawObservation
        let persistence: Persistence
        let rawBaseline: Data?
        let rawSaved: Data?
        let retired: [HostedFunctionalProcessIdentity]
        let drain: DrainFacts
    }

    struct RemovalFacts {
        let sourceCommit: String
        let session: String
        let owner: String
        let caseSHA256: String
        let capturedVersions: [String]
        let physicallyAbsentBeforeReinstall: [String]
        let finalPhysicallyAbsent: [String]
        let capturedLeaseTokens: [String]
        let releasedLeaseTokens: [String]
        let leasesReleased: Bool
    }

    struct SentinelFacts {
        let sourceCommit: String
        let session: String
        let owner: String
        let caseSHA256: String
        let before: Data
        let after: Data
    }

    struct JournalEnvelope: Encodable {
        let schema: Int
        let payload: String
        let signature: String
    }

    struct UnsignedEvidence {
        let claim: [String: Any]
        let journalPayloads: [Data]
        private let stages: [[String: Any]]
        private let remainder: [String: Any]

        fileprivate init(
            claim: [String: Any], journalPayloads: [Data],
            stages: [[String: Any]], remainder: [String: Any]
        ) {
            self.claim = claim
            self.journalPayloads = journalPayloads
            self.stages = stages
            self.remainder = remainder
        }

        func observation(journalEnvelopes: [JournalEnvelope]) throws -> [String: Any] {
            guard journalEnvelopes.count == 3 else {
                throw FunctionalFailure.invalid("complete journal seals")
            }
            var observedStages: [[String: Any]] = []
            for index in 0..<3 {
                let seal = journalEnvelopes[index]
                guard seal.schema == 1, Data(seal.payload.utf8) == journalPayloads[index],
                    let signature = Data(base64Encoded: seal.signature), signature.count == 64,
                    signature.base64EncodedString() == seal.signature
                else { throw FunctionalFailure.invalid("exact unsigned journal seal payload") }
                var stage = stages[index]
                stage["mutationJournal"] = try FunctionalCollectedEvidence.object(seal)
                observedStages.append(stage)
            }
            var observed = remainder
            observed["stages"] = observedStages
            let bytes = try FunctionalBytes.canonical(observed)
            guard bytes.count <= 1_048_576 else {
                throw FunctionalFailure.invalid("bounded complete observation")
            }
            return observed
        }
    }

    private static let phases = ["initial", "updated", "reinstalled"]
    private static let maximumSafeInteger = 9_007_199_254_740_991
    private let sourceCommit: String
    private let session: String
    private let owner: String
    private let uid: UInt32
    private let policy: Policy
    private let caseSHA256: String
    private var stages: [CompletedStage] = []
    private var identifiers = Set<String>()
    private var processIDs = Set<Int32>()
    private var presentationIDs = Set<String>()
    private var engineGenerations = Set<String>()
    private var uiGenerations = Set<String>()
    private var failed = false
    private var finished = false

    init(sourceCommit: String, session: String, owner: String, uid: UInt32, compiledPolicy: Policy)
        throws
    {
        let definition = compiledPolicy.definition
        guard FunctionalBytes.hex(sourceCommit, length: 40), FunctionalBytes.uuid(session),
            definition.schema == 1, definition.owner == owner,
            HostedFunctionalActionContext.owners.contains(owner),
            compiledPolicy.semantics.map(\.phase) == Self.phases,
            ["original-control-callback", "native-accessibility"].contains(
                definition.activation.kind),
            ["state-transition", "owned-output"].contains(definition.activation.mutation.kind),
            ["checked-engine-readback", "owned-file-output", "owned-process-output"].contains(
                definition.observation.kind),
            Self.text(definition.activation.control), Self.text(definition.observation.name),
            Self.text(definition.persistence.name),
            definition.persistence.applicable
                || definition.persistence.name == "no-owned-persistent-record",
            !definition.operations.isEmpty, definition.operations.count <= 16,
            Set(definition.operations).count == definition.operations.count,
            definition.operations.contains(definition.activation.operation),
            definition.operations.allSatisfy({
                $0.range(
                    of: "^[A-Za-z][A-Za-z0-9_-]*(?:\\.[A-Za-z][A-Za-z0-9_-]*)+$",
                    options: .regularExpression) != nil
            }),
            !definition.activation.operation.split(separator: ".").contains(where: {
                ["read", "snapshot", "state", "list", "schema", "get", "poll"].contains(String($0))
            }), !definition.activation.sources.isEmpty, definition.activation.sources.count <= 8,
            Set(definition.activation.sources.map(\.path)).count
                == definition.activation.sources.count,
            definition.activation.sources.allSatisfy({
                $0.path.hasPrefix("Extensions/" + owner + "/")
                    && !$0.path.split(separator: "/", omittingEmptySubsequences: false).contains(
                        where: {
                            $0.isEmpty || $0 == "." || $0 == ".."
                        })
                    && FunctionalBytes.hex($0.sha256, length: 64)
            }), !definition.limits.isEmpty, Set(definition.limits).count == definition.limits.count,
            Set(definition.limits).isSubset(of: [
                "synthetic-platform-adapter", "private-filesystem",
                "loopback-service", "owned-pty", "bundled-content", "owned-toolchain",
                "privileged-role-unproved",
            ]),
            definition.activation.mutation.payloadKeys.count <= 32,
            Set(definition.activation.mutation.payloadKeys).count
                == definition.activation.mutation.payloadKeys.count,
            definition.activation.mutation.payloadKeys.allSatisfy({
                $0.range(of: "^[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil
            }),
            !definition.activation.mutation.payloadKeys.isEmpty
                || (owner == "terminal" && definition.activation.operation == "terminal.open")
        else { throw FunctionalFailure.invalid("source compiled evidence policy") }
        for rule in compiledPolicy.semantics {
            guard (rule.savedBefore != nil) == definition.persistence.applicable,
                (rule.savedAfter != nil) == definition.persistence.applicable,
                (rule.relation == .colorPickerHistory) == (owner == "colorPicker")
            else { throw FunctionalFailure.invalid("source compiled raw semantics") }
            try rule.before.requireCompiled()
            try rule.after.requireCompiled()
        }
        self.sourceCommit = sourceCommit
        self.session = session
        self.owner = owner
        self.uid = uid
        policy = compiledPolicy
        caseSHA256 = FunctionalBytes.digest(try Self.encode(definition))
    }

    func appendStage(_ stage: CompletedStage) throws {
        guard !failed, !finished, stages.count < 3 else {
            throw FunctionalFailure.invalid("closed evidence collector")
        }
        do {
            try validate(stage, index: stages.count)
            stages.append(stage)
        } catch {
            failed = true
            throw error
        }
    }

    func finish(removal: RemovalFacts, sentinels: SentinelFacts) throws -> UnsignedEvidence {
        guard !failed, !finished, stages.count == 3 else {
            throw FunctionalFailure.invalid("incomplete three phase evidence")
        }
        do {
            let versions = [stages[0].capability.version, stages[1].capability.version]
            let leases = stages.flatMap { $0.drain.capturedLeaseTokens }
            guard removal.sourceCommit == sourceCommit, removal.session == session,
                removal.owner == owner,
                removal.caseSHA256 == caseSHA256, removal.capturedVersions == versions,
                removal.physicallyAbsentBeforeReinstall == versions,
                removal.finalPhysicallyAbsent == versions,
                removal.leasesReleased, Set(leases).count == leases.count,
                removal.capturedLeaseTokens == leases,
                Set(removal.releasedLeaseTokens) == Set(leases),
                removal.releasedLeaseTokens.count == leases.count,
                sentinels.sourceCommit == sourceCommit, sentinels.session == session,
                sentinels.owner == owner,
                sentinels.caseSHA256 == caseSHA256, !sentinels.before.isEmpty,
                sentinels.before.count <= 1_048_576, sentinels.before == sentinels.after
            else {
                throw FunctionalFailure.invalid(
                    "actual scoped removal release and sentinel preservation")
            }
            var observedStages: [[String: Any]] = []
            var claims: [[String: Any]] = []
            for stage in stages {
                let selected = stage.journal.records.last!
                var activation = try Self.object(policy.definition.activation)
                activation["ui"] = try Self.object(stage.capability.ui)
                activation["request"] = try Self.object(selected.request)
                activation["payload"] = selected.payload
                activation["sequence"] = selected.sendSequence
                let authoritative: [String: Any] = [
                    "kind": policy.definition.observation.kind,
                    "name": policy.definition.observation.name,
                    "reader": "independent-hosted-producer",
                    "observationID": stage.authoritative.observationID,
                    "afterAcknowledgement": stage.authoritative.sequence
                        > selected.acknowledgement.sequence,
                    "observationSHA256": FunctionalBytes.digest(stage.authoritative.bytes),
                    "expectedSHA256": selected.transition.after.expectedSHA256,
                    "sequence": stage.authoritative.sequence,
                ]
                observedStages.append([
                    "capability": try Self.object(stage.capability),
                    "admission": try Self.object(stage.admission.admission),
                    "activation": activation,
                    "acknowledgement": try Self.object(selected.acknowledgement),
                    "authoritative": authoritative, "retired": try stage.retired.map(Self.object),
                    "persistence": try Self.object(stage.persistence),
                    "transition": try Self.object(selected.transition),
                ])
                claims.append([
                    "phase": stage.capability.phase, "requestID": selected.request.requestID,
                    "capabilitySHA256": stage.journal.capabilitySHA256,
                    "observationSHA256": FunctionalBytes.digest(stage.authoritative.bytes),
                ])
            }
            let captured = stages.flatMap { [$0.capability.engine, $0.capability.ui] }
            let claim: [String: Any] = [
                "schema": 1, "sourceCommit": sourceCommit,
                "session": session, "owner": owner, "caseSHA256": caseSHA256, "stages": claims,
            ]
            let observed: [String: Any] = [
                "schema": 1, "authority": "independent-hosted-producer",
                "execution": "hosted-macos-native", "sourceCommit": sourceCommit,
                "session": session,
                "owner": owner, "uid": uid, "caseSHA256": caseSHA256,
                "packagePair": [
                    "scope": stages[0].capability.pairScope,
                    "previous": [
                        "version": versions[0], "packageSHA256": stages[0].capability.packageSHA256,
                    ],
                    "current": [
                        "version": versions[1], "packageSHA256": stages[1].capability.packageSHA256,
                    ],
                    "publicAdmissionSHA256": NSNull(),
                ],
                "naturalExit": [
                    "cleanupStarted": stages.contains { $0.drain.cleanupStarted },
                    "captured": try captured.map(Self.object),
                    "absent": try stages.flatMap { $0.drain.absent }.map(Self.object),
                ],
                "removal": [
                    "capturedVersions": removal.capturedVersions,
                    "physicallyAbsentBeforeReinstall": removal.physicallyAbsentBeforeReinstall,
                    "finalPhysicallyAbsent": removal.finalPhysicallyAbsent,
                    "leasesReleased": removal.leasesReleased,
                ],
                "agenticSentinels": [
                    "beforeSHA256": FunctionalBytes.digest(sentinels.before),
                    "afterSHA256": FunctionalBytes.digest(sentinels.after),
                ],
            ]
            let journalPayloads = try stages.map { try Self.encode($0.journal) }
            guard journalPayloads.allSatisfy({ !$0.isEmpty && $0.count <= 1_048_576 }),
                try FunctionalBytes.canonical(claim).count <= 1_048_576
            else { throw FunctionalFailure.invalid("bounded unsigned complete claim and journals") }
            let result = UnsignedEvidence(
                claim: claim, journalPayloads: journalPayloads,
                stages: observedStages, remainder: observed)
            finished = true
            return result
        } catch {
            failed = true
            throw error
        }
    }

    private func validate(_ stage: CompletedStage, index: Int) throws {
        let cap = stage.capability
        let definition = policy.definition
        let rule = policy.semantics[index]
        let digest = FunctionalBytes.digest(try Self.encode(cap))
        let binding = Binding(
            sourceCommit: sourceCommit, session: session, owner: owner, caseSHA256: caseSHA256,
            phase: Self.phases[index], capabilitySHA256: digest,
            presentationID: stage.presentationID)
        let sequences =
            [
                stage.journal.baseline.sequence, stage.journal.loadSequence,
                stage.journal.sealedThroughSequence, stage.authoritative.sequence,
                stage.persistence.sequence,
                stage.drain.engineStop.sequence, stage.drain.nativeStop.sequence,
            ]
            + stage.journal.records.flatMap {
                [
                    $0.sendSequence, $0.acknowledgement.sequence,
                    $0.transition.before.sequence, $0.transition.after.sequence,
                ]
            }
        guard sequences.allSatisfy({ $0 > 0 && $0 <= Self.maximumSafeInteger }),
            [cap.engine, cap.ui, stage.admission.observedHost].allSatisfy({
                $0.birthSeconds > 0 && $0.birthSeconds <= Int64(Self.maximumSafeInteger)
            })
        else {
            throw FunctionalFailure.invalid("original contract safe numeric sequences and births")
        }
        try stage.admission.observedHost.validate(uid: uid)
        try cap.validate(
            source: sourceCommit, owner: owner, session: session, uid: uid,
            root: cap.fixtureRoot, caseSHA256: caseSHA256, operations: definition.operations,
            engine: cap.engine, ui: cap.ui)
        guard cap.phase == Self.phases[index], cap.pairScope == "synthetic-development",
            cap.activationOperation == definition.activation.operation,
            stage.admission.binding == binding, stage.drain.binding == binding,
            stage.admission.observedEngine == cap.engine, stage.admission.observedUI == cap.ui,
            stage.admission.observedHost.pid != cap.engine.pid,
            stage.admission.observedHost.pid != cap.ui.pid,
            stage.admission.admission.complete, FunctionalBytes.uuid(stage.presentationID),
            presentationIDs.insert(stage.presentationID).inserted,
            processIDs.insert(cap.engine.pid).inserted, processIDs.insert(cap.ui.pid).inserted,
            engineGenerations.insert(
                String(cap.engine.birthSeconds) + ":" + String(cap.engine.birthMicroseconds)
            ).inserted,
            uiGenerations.insert(
                String(cap.ui.birthSeconds) + ":" + String(cap.ui.birthMicroseconds)
            ).inserted
        else { throw FunctionalFailure.invalid("actual admission and unique scoped generation") }
        if index == 0 {
            guard stage.retired.isEmpty else {
                throw FunctionalFailure.invalid("initial retired generations")
            }
        } else {
            let prior = stages[index - 1].capability
            guard stage.admission.observedHost == stages[0].admission.observedHost,
                cap.fixtureRoot == prior.fixtureRoot, cap.hostIdentifier == prior.hostIdentifier,
                cap.home == prior.home, cap.dataDirectory == prior.dataDirectory,
                cap.hostABI == prior.hostABI,
                cap.pairScope == prior.pairScope, cap.previousVersion == prior.previousVersion,
                cap.currentVersion == prior.currentVersion,
                cap.engine.birthSeconds != prior.engine.birthSeconds
                    || cap.engine.birthMicroseconds != prior.engine.birthMicroseconds,
                cap.ui.birthSeconds != prior.ui.birthSeconds
                    || cap.ui.birthMicroseconds != prior.ui.birthMicroseconds,
                stage.retired == [prior.engine, prior.ui],
                index == 1
                    ? cap.packageSHA256 != prior.packageSHA256
                    : cap.packageSHA256 == prior.packageSHA256
            else { throw FunctionalFailure.invalid("retired package and birth sequencing") }
        }
        guard let selectedID = stage.journal.records.last?.request.requestID else {
            throw FunctionalFailure.invalid("missing actual mutation")
        }
        let selected = try stage.journal.validate(
            context: cap, capabilitySHA256: digest,
            presentationID: stage.presentationID,
            persistenceApplicable: definition.persistence.applicable,
            mutationKind: definition.activation.mutation.kind,
            payloadKeys: definition.activation.mutation.payloadKeys,
            selectedRequestID: selectedID, persistenceSequence: stage.persistence.sequence)
        try insert(stage.journal.baseline.observationID)
        guard stage.rawMutations.count == stage.journal.records.count else {
            throw FunctionalFailure.invalid("complete raw mutation observations")
        }
        for (record, raw) in zip(stage.journal.records, stage.rawMutations) {
            try insert(record.request.requestID)
            try insert(record.activationID)
            try insert(record.transition.before.observationID)
            try insert(record.transition.after.observationID)
            guard raw.requestID == record.request.requestID else {
                throw FunctionalFailure.invalid("raw request binding")
            }
            try validate(raw.before, record.transition.before)
            try validate(raw.after, record.transition.after)
        }
        guard let raw = stage.rawMutations.last,
            try rule.before.matches(rawValue(raw.before.bytes)),
            try rule.after.matches(rawValue(raw.after.bytes)),
            raw.before.bytes != raw.after.bytes,
            stage.authoritative.bytes == raw.after.bytes,
            stage.authoritative.sequence > selected.acknowledgement.sequence,
            stage.persistence.sequence > stage.authoritative.sequence,
            stage.journal.sealedThroughSequence >= stage.persistence.sequence
        else {
            throw FunctionalFailure.invalid("source literal action effect and observation order")
        }
        try validateRelation(stage, rule: rule, binding: binding)
        try requireCanonicalRaw(stage.authoritative.bytes)
        try insert(stage.authoritative.observationID)
        try validatePersistence(stage, rule: rule, index: index)
        let requests = try validateRequests(stage, selected: selected)
        try validateDrain(stage, requests: requests)
    }

    private enum ColorHistoryProfile: String, Codable {
        case sRGB, displayP3
    }

    private struct ColorHistorySwatch: Codable, Equatable {
        let id: UUID
        let red: Double
        let green: Double
        let blue: Double
        let profile: ColorHistoryProfile
        let pickedAt: Date
    }

    private struct ColorPreferences {
        let values: [String: Any]
        let history: [ColorHistorySwatch]
        let limit: Int
        let profile: String
    }

    static func colorPickerHistoryObservation(preferences: Data) throws -> Data {
        _ = try colorPreferences(preferences)
        return try FunctionalBytes.canonical([
            "preferencesSHA256": [
                "maskedSHA256": FunctionalBytes.digest(
                    Data(preferences.base64EncodedString().utf8))
            ]
        ])
    }

    private static func colorPreferences(_ bytes: Data) throws -> ColorPreferences {
        guard !bytes.isEmpty, bytes.count <= 1_048_576,
            let values = try PropertyListSerialization.propertyList(from: bytes, format: nil)
                as? [String: Any],
            values["colorPickerProfile"] as? String == "sRGB",
            let number = values["colorPickerHistorySize"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            let limit = Int(exactly: number.doubleValue), (1...100).contains(limit)
        else { throw FunctionalFailure.invalid("original color preference fields") }
        let history: [ColorHistorySwatch]
        if let data = values["colorPickerHistory"] as? Data {
            guard !data.isEmpty, data.count <= 1_048_576,
                let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                rows.allSatisfy({
                    Set($0.keys) == ["id", "red", "green", "blue", "profile", "pickedAt"]
                })
            else { throw FunctionalFailure.invalid("original color history codec") }
            history = try JSONDecoder().decode([ColorHistorySwatch].self, from: data)
        } else {
            guard values["colorPickerHistory"] == nil else {
                throw FunctionalFailure.invalid("original color history data")
            }
            history = []
        }
        guard !history.isEmpty, history.count <= limit,
            Set(history.map(\.id)).count == history.count,
            history.allSatisfy({
                $0.red.isFinite && $0.green.isFinite && $0.blue.isFinite
                    && (0...1).contains($0.red) && (0...1).contains($0.green)
                    && (0...1).contains($0.blue)
                    && $0.pickedAt.timeIntervalSinceReferenceDate.isFinite
            })
        else { throw FunctionalFailure.invalid("original color history values") }
        return ColorPreferences(values: values, history: history, limit: limit, profile: "sRGB")
    }

    private static func propertyValue(_ value: Any, depth: Int = 0) throws -> SemanticValue {
        guard depth < 32 else {
            throw FunctionalFailure.invalid("bounded original preference depth")
        }
        if let value = value as? Data {
            return .object(["data": .string(value.base64EncodedString())])
        }
        if let value = value as? Date {
            guard value.timeIntervalSinceReferenceDate.isFinite else {
                throw FunctionalFailure.invalid("finite original preference date")
            }
            return .object(["date": .number(value.timeIntervalSinceReferenceDate)])
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .object(["boolean": .boolean(value.boolValue)])
            }
            guard value.doubleValue.isFinite else {
                throw FunctionalFailure.invalid("finite original preference number")
            }
            return .object([
                "number": .string(value.stringValue),
                "type": .string(String(cString: value.objCType)),
            ])
        }
        if let value = value as? String { return .object(["string": .string(value)]) }
        if let values = value as? [Any] {
            guard values.count <= 65_536 else {
                throw FunctionalFailure.invalid("bounded original preference array")
            }
            return .array(try values.map { try propertyValue($0, depth: depth + 1) })
        }
        if let values = value as? [String: Any] {
            guard values.count <= 128 else {
                throw FunctionalFailure.invalid("bounded original preference fields")
            }
            return .object(try values.mapValues { try propertyValue($0, depth: depth + 1) })
        }
        throw FunctionalFailure.invalid("original property list value")
    }

    private func validateRelation(_ stage: CompletedStage, rule: PhaseSemantics, binding: Binding)
        throws
    {
        guard rule.relation == .colorPickerHistory else {
            guard stage.colorPickerHistory.isEmpty else {
                throw FunctionalFailure.invalid("foreign color relation facts")
            }
            return
        }
        guard stage.colorPickerHistory.count == stage.rawMutations.count else {
            throw FunctionalFailure.invalid("complete original color relation facts")
        }
        for (fact, raw) in zip(stage.colorPickerHistory, stage.rawMutations) {
            guard fact.binding == binding, fact.requestID == raw.requestID,
                raw.before.bytes
                    == (try Self.colorPickerHistoryObservation(
                        preferences: fact.providerBeforePreferences)),
                raw.after.bytes
                    == (try Self.colorPickerHistoryObservation(
                        preferences: fact.providerAfterPreferences))
            else { throw FunctionalFailure.invalid("actual color provider observation binding") }
            let before = try Self.colorPreferences(fact.rawBeforePreferences)
            let after = try Self.colorPreferences(fact.rawAfterPreferences)
            let providerBefore = try Self.colorPreferences(fact.providerBeforePreferences)
            let providerAfter = try Self.colorPreferences(fact.providerAfterPreferences)
            guard providerBefore.history == before.history, providerAfter.history == after.history,
                providerBefore.limit == before.limit, providerAfter.limit == after.limit,
                providerBefore.profile == before.profile, providerAfter.profile == after.profile,
                before.limit == after.limit,
                try Self.propertyValue(before.values.filter { $0.key != "colorPickerHistory" })
                    == Self.propertyValue(after.values.filter { $0.key != "colorPickerHistory" }),
                let retained = after.history.first,
                after.history.count == min(before.history.count + 1, before.limit),
                !before.history.contains(where: { $0.id == retained.id }),
                Array(after.history.dropFirst())
                    == Array(before.history.prefix(after.history.count - 1)),
                retained.profile == .sRGB,
                abs(retained.red - 0.25) < 0.001, abs(retained.green - 0.5) < 0.001,
                abs(retained.blue - 0.75) < 0.001
            else { throw FunctionalFailure.invalid("original color history relation") }
        }
    }

    private func validatePersistence(_ stage: CompletedStage, rule: PhaseSemantics, index: Int)
        throws
    {
        let persistence = stage.persistence
        let baseline = stage.journal.baseline
        let expectedBefore = try rule.savedBefore.map(Self.encode)
        let expectedAfter = try rule.savedAfter.map(Self.encode)
        guard stage.rawBaseline == expectedBefore, stage.rawSaved == expectedAfter,
            baseline.readbackSHA256 == expectedBefore.map(FunctionalBytes.digest),
            baseline.expectedSHA256 == baseline.readbackSHA256,
            persistence.name == policy.definition.persistence.name,
            persistence.readbackSHA256 == expectedAfter.map(FunctionalBytes.digest),
            persistence.expectedSHA256 == persistence.readbackSHA256
        else { throw FunctionalFailure.invalid("literal saved raw semantics") }
        if policy.definition.persistence.applicable && index > 0 {
            guard persistence.readbackSHA256 == stages[0].persistence.readbackSHA256,
                let prior = persistence.beforeActivation, prior.reader == baseline.reader,
                prior.observationID == baseline.observationID, prior.sequence == baseline.sequence,
                prior.readbackSHA256 == baseline.readbackSHA256,
                prior.expectedSHA256 == baseline.expectedSHA256,
                prior.capabilitySHA256 == stage.journal.capabilitySHA256,
                prior.engine == stage.capability.engine, prior.ui == stage.capability.ui,
                prior.beforeRequestID == stage.journal.records.first?.request.requestID,
                prior.readbackSHA256
                    == (owner == "blitztree"
                        ? expectedBefore.map(FunctionalBytes.digest)
                        : stages[0].persistence.readbackSHA256)
            else {
                throw FunctionalFailure.invalid(
                    "saved before construction and first request binding")
            }
        } else {
            guard persistence.beforeActivation == nil else {
                throw FunctionalFailure.invalid("unexpected saved prior observation")
            }
        }
    }

    private struct RetiringRequests {
        let admitted: Set<String>
        let pending: Set<String>
    }

    private func validateRequests(
        _ stage: CompletedStage, selected: HostedFunctionalMutationJournal.Record
    ) throws -> RetiringRequests {
        struct Pending {
            let operation: String
            let payloadSHA256: String
            var next: RequestEvent
            var responseSHA256: String?
            var outcome: Bool?
        }
        var pending: [String: Pending] = [:]
        var completed: [String: RequestRecord] = [:]
        var admitted = Set<String>()
        let journalTokens = Set(stage.journal.records.map { $0.request.requestID })
        guard !stage.requestRecords.isEmpty, stage.requestRecords.count <= 4096 else {
            throw FunctionalFailure.invalid("bounded completed original request journal")
        }
        for (ordinal, event) in stage.requestRecords.enumerated() {
            guard event.ordinal == ordinal, FunctionalBytes.uuid(event.token),
                event.presentationID == stage.presentationID,
                stage.capability.operations.contains(event.operation),
                FunctionalBytes.hex(event.payloadSHA256, length: 64)
            else {
                throw FunctionalFailure.invalid("original event binding")
            }
            switch event.event {
            case .hostBefore:
                guard event.caller == stage.admission.observedHost,
                    event.outcome == nil, event.responseSHA256 == nil, pending.count < 8,
                    pending[event.token] == nil, completed[event.token] == nil
                else { throw FunctionalFailure.invalid("original request start") }
                if !journalTokens.contains(event.token) { try insert(event.token) }
                pending[event.token] = Pending(
                    operation: event.operation,
                    payloadSHA256: event.payloadSHA256, next: .engineBefore)
            case .engineBefore, .engineAfter, .hostAfter, .nativeReply:
                guard var current = pending[event.token], current.next == event.event,
                    current.operation == event.operation,
                    current.payloadSHA256 == event.payloadSHA256
                else { throw FunctionalFailure.invalid("missing or out of order original event") }
                if event.event == .engineBefore || event.event == .engineAfter {
                    guard event.caller == stage.capability.engine else {
                        throw FunctionalFailure.invalid("engine event birth")
                    }
                } else {
                    guard event.caller == stage.admission.observedHost
                    else { throw FunctionalFailure.invalid("forwarding host birth") }
                    let first = stage.requestRecords.first { $0.token == event.token }
                    guard event.caller == first?.caller else {
                        throw FunctionalFailure.invalid("forwarding host changed")
                    }
                }
                if event.event == .engineBefore {
                    guard event.outcome == nil, event.responseSHA256 == nil else {
                        throw FunctionalFailure.invalid("premature original response")
                    }
                } else {
                    if event.outcome == true {
                        guard let hash = event.responseSHA256, FunctionalBytes.hex(hash, length: 64)
                        else {
                            throw FunctionalFailure.invalid("actual original response hash")
                        }
                    } else {
                        guard event.outcome == false, event.responseSHA256 == nil else {
                            throw FunctionalFailure.invalid("missing original response outcome")
                        }
                    }
                    if event.event == .engineAfter {
                        current.responseSHA256 = event.responseSHA256
                        current.outcome = event.outcome
                    } else {
                        guard event.responseSHA256 == current.responseSHA256,
                            event.outcome == current.outcome
                        else {
                            throw FunctionalFailure.invalid(
                                "response changed between actual receivers")
                        }
                    }
                }
                switch event.event {
                case .engineBefore:
                    guard admitted.insert(event.token).inserted else {
                        throw FunctionalFailure.invalid("replayed engine command admission")
                    }
                    current.next = .engineAfter
                case .engineAfter: current.next = .hostAfter
                case .hostAfter: current.next = .nativeReply
                case .nativeReply:
                    pending.removeValue(forKey: event.token)
                    completed[event.token] = event
                case .hostBefore: throw FunctionalFailure.invalid("replayed request start")
                }
                if event.event != .nativeReply { pending[event.token] = current }
            }
        }
        guard Set(pending.keys).isSubset(of: admitted) else {
            throw FunctionalFailure.invalid("unfinished request without actual engine admission")
        }
        for record in stage.journal.records {
            guard let event = completed[record.request.requestID],
                event.outcome == record.acknowledgement.success,
                event.operation == record.request.operation,
                event.payloadSHA256 == record.request.payloadSHA256,
                event.responseSHA256 == record.acknowledgement.responseSHA256
            else { throw FunctionalFailure.invalid("mutation lacks actual five event completion") }
        }
        guard completed[selected.request.requestID]?.outcome == true else {
            throw FunctionalFailure.invalid("selected original action did not complete")
        }
        return RetiringRequests(admitted: admitted, pending: Set(pending.keys))
    }

    private func validateDrain(_ stage: CompletedStage, requests: RetiringRequests) throws {
        let drain = stage.drain
        let peers = [stage.capability.engine, stage.capability.ui]
        let cancelled = Set(drain.cancelledRequestTokens)
        let requested = Set(drain.retirementRequestedTokens)
        let joined = Set(drain.joinedRequestTokens)
        let obligations = requests.pending.union(cancelled).union(requested)
        guard cancelled.count == drain.cancelledRequestTokens.count,
            requested.count == drain.retirementRequestedTokens.count,
            joined.count == drain.joinedRequestTokens.count,
            cancelled.isSubset(of: requests.admitted), requested.isSubset(of: requests.admitted),
            joined == obligations
        else { throw FunctionalFailure.invalid("actual cancelled and pending receiver joins") }
        guard !drain.cleanupStarted, FunctionalBytes.uuid(drain.stopPreparationToken),
            drain.captured == peers, drain.absent == peers,
            Set(drain.capturedLeaseTokens).count == drain.capturedLeaseTokens.count,
            drain.capturedLeaseTokens.allSatisfy(FunctionalBytes.uuid),
            Set(drain.releasedLeaseTokens).count == drain.releasedLeaseTokens.count,
            Set(drain.capturedLeaseTokens) == Set(drain.releasedLeaseTokens)
        else { throw FunctionalFailure.invalid("actual natural drain and released leases") }
        let engine = drain.engineStop
        let native = drain.nativeStop
        try validateStop(engine.stop, operations: ["stop"])
        try validateStop(
            engine.preparation, operations: ["prepareDisable", "prepareApplicationQuit"])
        try validateStop(native.stop, operations: ["stop"])
        guard engine.worker == peers[0], engine.terminationStatus == 0,
            engine.terminationReason == 1,
            engine.signalAttempts.isEmpty, engine.sequence > stage.journal.sealedThroughSequence,
            native.ui == peers[1], native.engine == peers[0], native.signalAttempts.isEmpty,
            native.sequence > stage.journal.sealedThroughSequence,
            native.stop.requestID == drain.stopPreparationToken,
            native.joinedTasks == ["engine-receivers"],
            native.invalidations.allSatisfy({
                $0.site == "retired-process-release" && ($0.peer == nil || $0.peer == peers[1])
                    && $0.peerWasRunning != true
            })
        else { throw FunctionalFailure.invalid("actual full engine and native stop fieldsets") }
        try validateAbsent(engine.observedBirths, absent: engine.absentBirths)
        try validateAbsent(native.observedBirths, absent: native.absentBirths)
        try insert(engine.stop.requestID)
        try insert(engine.preparation.requestID)
        try insert(native.stop.requestID)
    }

    private func validateStop(_ stop: StopAcknowledgement, operations: Set<String>) throws {
        guard FunctionalBytes.uuid(stop.requestID), stop.responseToken == stop.requestID,
            operations.contains(stop.operation), stop.outcome
        else {
            throw FunctionalFailure.invalid("actual original stop or preparation acknowledgement")
        }
    }

    private func validateAbsent(_ captured: [CapturedBirth], absent: [CapturedBirth]) throws {
        guard captured.count <= 256, Set(captured).count == captured.count, captured == absent,
            captured.allSatisfy({
                $0.pid > 1 && $0.birthSeconds > 0 && (0..<1_000_000).contains($0.birthMicroseconds)
            })
        else { throw FunctionalFailure.invalid("all captured original descendant births absent") }
    }

    private func validate(
        _ raw: RawObservation, _ observed: HostedFunctionalMutationJournal.Observation
    ) throws {
        try requireCanonicalRaw(raw.bytes)
        guard raw.observationID == observed.observationID, raw.sequence == observed.sequence,
            FunctionalBytes.digest(raw.bytes) == observed.observationSHA256,
            observed.expectedSHA256 == observed.observationSHA256
        else { throw FunctionalFailure.invalid("raw independently observed transition bytes") }
    }

    private func requireCanonicalRaw(_ bytes: Data) throws {
        _ = try rawValue(bytes)
    }

    private func rawValue(_ bytes: Data) throws -> Any {
        guard !bytes.isEmpty, bytes.count <= 1_048_576 else {
            throw FunctionalFailure.invalid("bounded raw semantic bytes")
        }
        let value = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
        guard try FunctionalBytes.canonical(value) == bytes
        else { throw FunctionalFailure.invalid("canonical raw semantic container") }
        return value
    }

    private func insert(_ identifier: String) throws {
        guard FunctionalBytes.uuid(identifier), identifiers.insert(identifier).inserted else {
            throw FunctionalFailure.invalid("reused evidence identifier")
        }
    }

    fileprivate static func text(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    fileprivate static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    fileprivate static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try FunctionalBytes.object(encode(value))
    }
}
