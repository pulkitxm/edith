import Foundation
import FunctionalActionContract
import Testing
@testable import FunctionalProducerModels

struct FunctionalCollectedEvidenceTests {
    private typealias Evidence = FunctionalCollectedEvidence
    private let source = String(repeating: "a", count: 40)
    private let session = "00000000-0000-4000-8000-000000000001"
    private var owner = "keepAwake"
    private let uid: UInt32 = 501

    private func identifier(_ value: Int) -> String {
        "00000000-0000-4000-8000-" + String(format: "%012d", value)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ value: [String: Any], as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: FunctionalBytes.canonical(value))
    }

    private var policy: Evidence.Policy {
        let activation = Evidence.ActivationPolicy(
            kind: "native-accessibility", control: "Toggle awake",
            operation: "keepAwake.set",
            sources: [
                .init(
                    path: "Extensions/" + owner + "/Test.swift",
                    sha256: String(repeating: "a", count: 64))
            ],
            mutation: .init(kind: "state-transition", payloadKeys: ["enabled"]))
        let definition = Evidence.Definition(
            schema: 1, owner: owner, activation: activation,
            operations: ["keepAwake.set", "keepAwake.read"],
            observation: .init(kind: "checked-engine-readback", name: "awake-state"),
            persistence: .init(applicable: true, name: "awake-preference"),
            limits: ["synthetic-platform-adapter"])
        let before: Evidence.SemanticValue = .object(["enabled": .boolean(false)])
        let after: Evidence.SemanticValue = .object(["enabled": .boolean(true)])
        return .init(
            definition: definition,
            semantics: ["initial", "updated", "reinstalled"].enumerated().map { index, phase in
                .init(
                    phase: phase, before: .literal(before), after: .literal(after),
                    savedBefore: index == 0 ? before : after, savedAfter: after,
                    relation: owner == "colorPicker" ? .colorPickerHistory : nil)
            })
    }

    private var fullAdmission: Evidence.Admission {
        .init(
            heldRootPinned: true, heldDescriptorPinned: true, sourceClean: true, sourcePinned: true,
            payloadSignatureVerified: true, architectureVerified: true, hostABIVerified: true,
            originalFactoryUnchanged: true, originalControlsUnchanged: true,
            staleGenerationRejected: true)
    }

    private func collector(_ compiledPolicy: Evidence.Policy? = nil) throws -> Evidence {
        try Evidence(
            sourceCommit: source, session: session, owner: owner, uid: uid,
            compiledPolicy: compiledPolicy ?? policy)
    }

    private struct Fixture {
        var host: HostedFunctionalProcessIdentity
        var capability: [String: Any]
        var presentationID: String
        var journal: [String: Any]
        var admission: Evidence.Admission
        var requestRecords: [Evidence.RequestRecord]
        var colorPreferences: [Data] = []
        var before: Evidence.RawObservation
        var after: Evidence.RawObservation
        var authoritative: Evidence.RawObservation
        var persistence: Evidence.Persistence
        var rawBaseline: Data?
        var rawSaved: Data?
        var retired: [HostedFunctionalProcessIdentity]
        var engineStop: Evidence.EngineStopReceipt
        var nativeStop: Evidence.NativeStopReceipt
        var captured: [HostedFunctionalProcessIdentity]
        var absent: [HostedFunctionalProcessIdentity]
        var joined: [String]
        var cancelled: [String] = []
        var retirementRequested: [String] = []
        var capturedLeases: [String]
        var releasedLeases: [String]
        var cleanupStarted = false
        var admissionBindingOwner: String?
        var drainBindingPhase: String?
    }

    private func fixture(_ index: Int) throws -> Fixture {
        let phase = ["initial", "updated", "reinstalled"][index]
        let offset = index * 100
        let root = "/synthetic/functional-fixture-" + session
        let caseHash = FunctionalBytes.digest(try encode(policy.definition))
        func process(_ pid: Int, seconds: Int) -> [String: Any] {
            [
                "pid": pid, "birthSeconds": seconds, "birthMicroseconds": 10, "uid": uid,
                "executableSHA256": String(repeating: "b", count: 64),
            ]
        }
        let engine = process(100 + offset, seconds: 1000 + offset)
        let ui = process(101 + offset, seconds: 1001 + offset)
        let host = try decode(process(900, seconds: 900), as: HostedFunctionalProcessIdentity.self)
        let cap: [String: Any] = [
            "schema": 1, "sourceCommit": source, "session": session,
            "owner": owner, "uid": uid, "fixtureRoot": root,
            "hostIdentifier": "com.pulkit.edith.tests.worker-" + session,
            "home": root + "/" + owner + "-home", "dataDirectory": root + "/data/" + owner,
            "hostABI": "edith-host-2", "caseSHA256": caseHash,
            "activationOperation": "keepAwake.set",
            "phase": phase, "pairScope": "synthetic-development", "previousVersion": "1.0.0",
            "currentVersion": "1.1.0", "version": index == 0 ? "1.0.0" : "1.1.0",
            "packageSHA256": String(repeating: index == 0 ? "c" : "d", count: 64),
            "engine": engine, "ui": ui, "operations": policy.definition.operations,
            "ownedPaths": [],
        ]
        let digest = FunctionalBytes.digest(try FunctionalBytes.canonical(cap))
        let presentation = identifier(90 + offset)
        let requestID = identifier(10 + offset)
        let payload = Data("{\"enabled\":true}".utf8)
        let beforeBytes = try encode(Evidence.SemanticValue.object(["enabled": .boolean(false)]))
        let afterBytes = try encode(Evidence.SemanticValue.object(["enabled": .boolean(true)]))
        let savedBefore = try encode(policy.semantics[index].savedBefore!)
        let savedAfter = try encode(policy.semantics[index].savedAfter!)
        let responseHash = String(repeating: "e", count: 64)
        let request: [String: Any] = [
            "schema": 1, "sourceCommit": source, "session": session, "owner": owner,
            "phase": phase, "capabilitySHA256": digest, "requestID": requestID,
            "operation": "keepAwake.set", "payloadSHA256": FunctionalBytes.digest(payload),
        ]
        let ack: [String: Any] = [
            "request": request, "engine": engine, "success": true,
            "responseSHA256": responseHash, "sequence": 5,
        ]
        let before: [String: Any] = [
            "observationID": identifier(20 + offset), "sequence": 3,
            "observationSHA256": FunctionalBytes.digest(beforeBytes),
            "expectedSHA256": FunctionalBytes.digest(beforeBytes),
        ]
        let after: [String: Any] = [
            "observationID": identifier(21 + offset), "sequence": 6,
            "observationSHA256": FunctionalBytes.digest(afterBytes),
            "expectedSHA256": FunctionalBytes.digest(afterBytes),
        ]
        let transition: [String: Any] = [
            "kind": "state-transition", "reader": "independent-hosted-producer",
            "capabilitySHA256": digest, "requestID": requestID, "before": before, "after": after,
        ]
        let mutation: [String: Any] = [
            "request": request, "activationID": identifier(11 + offset),
            "origin": "authenticated-original-control", "ui": ui, "engine": engine,
            "payload": payload.base64EncodedString(), "sendSequence": 4,
            "acknowledgement": ack, "transition": transition,
        ]
        let baseline: [String: Any] = [
            "reader": "independent-hosted-producer", "observationID": identifier(22 + offset),
            "sequence": 1, "readbackSHA256": FunctionalBytes.digest(savedBefore),
            "expectedSHA256": FunctionalBytes.digest(savedBefore),
        ]
        let journal: [String: Any] = [
            "schema": 1, "sourceCommit": source, "session": session, "owner": owner,
            "phase": phase, "capabilitySHA256": digest, "presentationID": presentation,
            "baseline": baseline,
            "loadSequence": 2, "records": [mutation], "sealedThroughSequence": 9,
        ]
        let engineIdentity = try decode(engine, as: HostedFunctionalProcessIdentity.self)
        let uiIdentity = try decode(ui, as: HostedFunctionalProcessIdentity.self)
        let events: [Evidence.RequestEvent] = [
            .hostBefore, .engineBefore, .engineAfter, .hostAfter, .nativeReply,
        ]
        let requestRecords = events.enumerated().map { ordinal, event in
            Evidence.RequestRecord(
                ordinal: ordinal, event: event, token: requestID, operation: "keepAwake.set",
                presentationID: presentation, payloadSHA256: FunctionalBytes.digest(payload),
                responseSHA256: ordinal < 2 ? nil : responseHash,
                caller: ordinal == 1 || ordinal == 2 ? engineIdentity : host,
                outcome: ordinal < 2 ? nil : true)
        }
        let prior: Evidence.PriorPersistence? =
            index == 0
            ? nil
            : .init(
                reader: "independent-hosted-producer",
                observationID: identifier(22 + offset), capabilitySHA256: digest,
                engine: engineIdentity,
                ui: uiIdentity, beforeRequestID: requestID, sequence: 1,
                readbackSHA256: FunctionalBytes.digest(savedBefore),
                expectedSHA256: FunctionalBytes.digest(savedBefore))
        let persistence = Evidence.Persistence(
            name: "awake-preference", readbackSHA256: FunctionalBytes.digest(savedAfter),
            expectedSHA256: FunctionalBytes.digest(savedAfter), beforeActivation: prior, sequence: 8
        )
        let retired: [HostedFunctionalProcessIdentity]
        if index == 0 {
            retired = []
        } else {
            retired = try [
                process(100 + offset - 100, seconds: 1000 + offset - 100),
                process(101 + offset - 100, seconds: 1001 + offset - 100),
            ].map { try decode($0, as: HostedFunctionalProcessIdentity.self) }
        }
        let observedEngine = Evidence.CapturedBirth(
            pid: engineIdentity.pid, birthSeconds: engineIdentity.birthSeconds,
            birthMicroseconds: engineIdentity.birthMicroseconds)
        let observedUI = Evidence.CapturedBirth(
            pid: uiIdentity.pid, birthSeconds: uiIdentity.birthSeconds,
            birthMicroseconds: uiIdentity.birthMicroseconds)
        let engineStop = Evidence.EngineStopReceipt(
            stop: .init(
                requestID: identifier(30 + offset), responseToken: identifier(30 + offset),
                operation: "stop", outcome: true),
            preparation: .init(
                requestID: identifier(32 + offset), responseToken: identifier(32 + offset),
                operation: "prepareDisable", outcome: true),
            worker: engineIdentity, observedBirths: [observedEngine],
            absentBirths: [observedEngine],
            terminationStatus: 0, terminationReason: 1, signalAttempts: [], sequence: 10)
        let nativeStop = Evidence.NativeStopReceipt(
            stop: .init(
                requestID: identifier(50 + offset), responseToken: identifier(50 + offset),
                operation: "stop", outcome: true),
            ui: uiIdentity, engine: engineIdentity, observedBirths: [observedUI],
            absentBirths: [observedUI],
            signalAttempts: [], joinedTasks: ["engine-receivers"],
            invalidations: [
                .init(site: "retired-process-release", peer: uiIdentity, peerWasRunning: false)
            ], sequence: 11)
        return Fixture(
            host: host, capability: cap, presentationID: presentation, journal: journal,
            admission: fullAdmission,
            requestRecords: requestRecords,
            before: .init(observationID: identifier(20 + offset), sequence: 3, bytes: beforeBytes),
            after: .init(observationID: identifier(21 + offset), sequence: 6, bytes: afterBytes),
            authoritative: .init(
                observationID: identifier(23 + offset), sequence: 7, bytes: afterBytes),
            persistence: persistence, rawBaseline: savedBefore, rawSaved: savedAfter,
            retired: retired,
            engineStop: engineStop, nativeStop: nativeStop, captured: [engineIdentity, uiIdentity],
            absent: [engineIdentity, uiIdentity], joined: [],
            capturedLeases: [identifier(40 + offset)],
            releasedLeases: [identifier(40 + offset)])
    }

    private func stage(_ fixture: Fixture) throws -> Evidence.CompletedStage {
        let cap = try decode(fixture.capability, as: HostedFunctionalActionContext.self)
        let journal = try decode(fixture.journal, as: HostedFunctionalMutationJournal.self)
        let binding = Evidence.Binding(
            sourceCommit: source, session: session, owner: owner,
            caseSHA256: cap.caseSHA256, phase: cap.phase,
            capabilitySHA256: FunctionalBytes.digest(try encode(cap)),
            presentationID: fixture.presentationID)
        let admissionBinding = Evidence.Binding(
            sourceCommit: binding.sourceCommit, session: binding.session,
            owner: fixture.admissionBindingOwner ?? owner, caseSHA256: binding.caseSHA256,
            phase: binding.phase,
            capabilitySHA256: binding.capabilitySHA256, presentationID: binding.presentationID)
        let drainBinding = Evidence.Binding(
            sourceCommit: binding.sourceCommit, session: binding.session, owner: owner,
            caseSHA256: binding.caseSHA256, phase: fixture.drainBindingPhase ?? binding.phase,
            capabilitySHA256: binding.capabilitySHA256, presentationID: binding.presentationID)
        return .init(
            capability: cap, presentationID: fixture.presentationID,
            admission: .init(
                binding: admissionBinding, observedHost: fixture.host,
                observedEngine: cap.engine, observedUI: cap.ui,
                admission: fixture.admission),
            journal: journal, requestRecords: fixture.requestRecords,
            rawMutations: [
                .init(
                    requestID: journal.records.last!.request.requestID, before: fixture.before,
                    after: fixture.after)
            ],
            colorPickerHistory: fixture.colorPreferences.isEmpty
                ? []
                : [
                    .init(
                        binding: binding, requestID: journal.records.last!.request.requestID,
                        providerBeforePreferences: fixture.colorPreferences[0],
                        providerAfterPreferences: fixture.colorPreferences[1],
                        rawBeforePreferences: fixture.colorPreferences[2],
                        rawAfterPreferences: fixture.colorPreferences[3])
                ],
            authoritative: fixture.authoritative, persistence: fixture.persistence,
            rawBaseline: fixture.rawBaseline,
            rawSaved: fixture.rawSaved, retired: fixture.retired,
            drain: .init(
                binding: drainBinding,
                stopPreparationToken: identifier(
                    50 + (["initial", "updated", "reinstalled"].firstIndex(of: cap.phase) ?? 0)
                        * 100),
                engineStop: fixture.engineStop, nativeStop: fixture.nativeStop,
                captured: fixture.captured,
                absent: fixture.absent, cancelledRequestTokens: fixture.cancelled,
                retirementRequestedTokens: fixture.retirementRequested,
                joinedRequestTokens: fixture.joined,
                capturedLeaseTokens: fixture.capturedLeases,
                releasedLeaseTokens: fixture.releasedLeases, cleanupStarted: fixture.cleanupStarted)
        )
    }

    private func removal(leasesReleased: Bool = true, finalVersions: [String] = ["1.0.0", "1.1.0"])
        throws -> Evidence.RemovalFacts
    {
        let leases = [identifier(40), identifier(140), identifier(240)]
        return .init(
            sourceCommit: source, session: session, owner: owner,
            caseSHA256: FunctionalBytes.digest(try encode(policy.definition)),
            capturedVersions: ["1.0.0", "1.1.0"],
            physicallyAbsentBeforeReinstall: ["1.0.0", "1.1.0"],
            finalPhysicallyAbsent: finalVersions,
            capturedLeaseTokens: leases, releasedLeaseTokens: leases, leasesReleased: leasesReleased
        )
    }

    private func sentinels(after: Data? = nil) throws -> Evidence.SentinelFacts {
        let bytes = Data("{\"untouched\":true}".utf8)
        return .init(
            sourceCommit: source, session: session, owner: owner,
            caseSHA256: FunctionalBytes.digest(try encode(policy.definition)), before: bytes,
            after: after ?? bytes)
    }

    private func completed() throws -> Evidence {
        let collector = try collector()
        for index in 0..<3 { try collector.appendStage(stage(fixture(index))) }
        return collector
    }

    @Test func preservesClosedOriginalContractFieldsetsAfterThreePhases() throws {
        let collector = try completed()
        let unsigned = try collector.finish(removal: removal(), sentinels: sentinels())
        let issuer = try FunctionalIssuer(sourceCommit: source, session: session)
        let envelopes = try unsigned.journalPayloads.map { bytes in
            let journal = try FunctionalBytes.object(bytes)
            let seal = try FunctionalBytes.object(issuer.seal(journal))
            return Evidence.JournalEnvelope(
                schema: 1, payload: seal["payload"] as! String,
                signature: seal["signature"] as! String)
        }
        let observed = try unsigned.observation(journalEnvelopes: envelopes)
        #expect(
            Set(unsigned.claim.keys) == [
                "schema", "sourceCommit", "session", "owner", "caseSHA256", "stages",
            ])
        #expect(
            Set(observed.keys) == [
                "schema", "authority", "execution", "sourceCommit", "session", "owner", "uid",
                "caseSHA256", "stages", "packagePair", "naturalExit", "removal", "agenticSentinels",
            ])
        let stages = observed["stages"] as! [[String: Any]]
        for (index, observedStage) in stages.enumerated() {
            #expect(
                Set(observedStage.keys) == [
                    "capability", "admission", "activation", "acknowledgement", "authoritative",
                    "retired", "persistence", "transition", "mutationJournal",
                ])
            let sealed = try FunctionalBytes.canonical(observedStage["mutationJournal"]!)
            let journal = try HostedFunctionalMutationJournal.verify(
                sealed, issuerKey: issuer.publicKey)
            #expect(journal.phase == ["initial", "updated", "reinstalled"][index])
            #expect(journal.baseline.sequence < journal.loadSequence)
            #expect(journal.records.last!.transition.after.sequence < journal.sealedThroughSequence)
        }
        #expect(throws: (any Error).self) {
            try collector.finish(removal: removal(), sentinels: sentinels())
        }
    }

    @Test func rejectsIncompletePhasesAndStalePhaseOrder() throws {
        let collector = try collector()
        try collector.appendStage(stage(fixture(0)))
        #expect(throws: (any Error).self) {
            try collector.finish(removal: removal(), sentinels: sentinels())
        }
        #expect(throws: (any Error).self) { try collector.appendStage(stage(fixture(2))) }
        #expect(throws: (any Error).self) { try collector.appendStage(stage(fixture(1))) }
    }

    @Test func rejectsEveryMissingOriginalReceiverEvent() throws {
        for missing in 0..<5 {
            var fixture = try fixture(0)
            fixture.requestRecords.remove(at: missing)
            fixture.requestRecords = fixture.requestRecords.enumerated().map { ordinal, event in
                .init(
                    ordinal: ordinal, event: event.event, token: event.token,
                    operation: event.operation,
                    presentationID: event.presentationID, payloadSHA256: event.payloadSHA256,
                    responseSHA256: event.responseSHA256, caller: event.caller,
                    outcome: event.outcome)
            }
            #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
        }
    }

    @Test func rejectsChangedEventOrderAndResponse() throws {
        var fixture = try fixture(0)
        fixture.requestRecords.swapAt(1, 2)
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
        fixture = try self.fixture(0)
        let event = fixture.requestRecords[4]
        fixture.requestRecords[4] = .init(
            ordinal: event.ordinal, event: event.event, token: event.token,
            operation: event.operation, presentationID: event.presentationID,
            payloadSHA256: event.payloadSHA256,
            responseSHA256: String(repeating: "f", count: 64), caller: event.caller, outcome: true)
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
    }

    @Test func rejectsCrossOwnerAdmissionAndStaleDrain() throws {
        var fixture = try fixture(0)
        fixture.admissionBindingOwner = "terminal"
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
        fixture = try self.fixture(0)
        fixture.drainBindingPhase = "updated"
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
    }

    @Test func rejectsRawBadSemanticsEvenWithMatchingClaimedHashes() throws {
        try colorHistoryCounterexamples()
        var fixture = try fixture(0)
        let bad = Data("{\"enabled\":\"true\"}".utf8)
        let badHash = FunctionalBytes.digest(bad)
        fixture.after = .init(
            observationID: fixture.after.observationID, sequence: fixture.after.sequence, bytes: bad
        )
        fixture.authoritative = .init(
            observationID: fixture.authoritative.observationID,
            sequence: fixture.authoritative.sequence, bytes: bad)
        var records = fixture.journal["records"] as! [[String: Any]]
        var transition = records[0]["transition"] as! [String: Any]
        var after = transition["after"] as! [String: Any]
        after["observationSHA256"] = badHash
        after["expectedSHA256"] = badHash
        transition["after"] = after
        records[0]["transition"] = transition
        fixture.journal["records"] = records
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
        let scalarPolicy = Evidence.Policy(
            definition: policy.definition,
            semantics: policy.semantics.map {
                .init(
                    phase: $0.phase, before: .literal(.string("formula")),
                    after: .literal(.string("cask")), savedBefore: $0.savedBefore,
                    savedAfter: $0.savedAfter, relation: nil)
            })
        for value in ["\"cask\"", "\"CASK\"", "[\"cask\"]", " \"cask\"", "true"] {
            var scalar = try self.fixture(0)
            let beforeBytes = Data("\"formula\"".utf8)
            let afterBytes = Data(value.utf8)
            scalar.before = .init(
                observationID: scalar.before.observationID,
                sequence: scalar.before.sequence, bytes: beforeBytes)
            scalar.after = .init(
                observationID: scalar.after.observationID,
                sequence: scalar.after.sequence, bytes: afterBytes)
            scalar.authoritative = .init(
                observationID: scalar.authoritative.observationID,
                sequence: scalar.authoritative.sequence, bytes: afterBytes)
            var rows = scalar.journal["records"] as! [[String: Any]]
            var transition = rows[0]["transition"] as! [String: Any]
            for (name, bytes) in [("before", beforeBytes), ("after", afterBytes)] {
                var observed = transition[name] as! [String: Any]
                observed["observationSHA256"] = FunctionalBytes.digest(bytes)
                observed["expectedSHA256"] = FunctionalBytes.digest(bytes)
                transition[name] = observed
            }
            rows[0]["transition"] = transition
            scalar.journal["records"] = rows
            if value == "\"cask\"" {
                try collector(scalarPolicy).appendStage(stage(scalar))
            } else {
                #expect(throws: (any Error).self) {
                    try collector(scalarPolicy).appendStage(stage(scalar))
                }
            }
        }
        let arrayPolicy = Evidence.Policy(
            definition: policy.definition,
            semantics: policy.semantics.map {
                .init(
                    phase: $0.phase, before: .literal(.array([.integer(0)])),
                    after: .array(
                        minimumCount: 1, maximumCount: 1,
                        element: .integer(minimum: 1, maximum: 1)),
                    savedBefore: $0.savedBefore, savedAfter: $0.savedAfter, relation: $0.relation)
            })
        for value in ["[1]", "[true]", "[\"1\"]", "[1,1]", "[]", " [1]", "{\"value\":1}"] {
            var arrays = try self.fixture(0)
            let beforeBytes = Data("[0]".utf8)
            let afterBytes = Data(value.utf8)
            arrays.before = .init(
                observationID: arrays.before.observationID, sequence: arrays.before.sequence,
                bytes: beforeBytes)
            arrays.after = .init(
                observationID: arrays.after.observationID, sequence: arrays.after.sequence,
                bytes: afterBytes)
            arrays.authoritative = .init(
                observationID: arrays.authoritative.observationID,
                sequence: arrays.authoritative.sequence, bytes: afterBytes)
            var records = arrays.journal["records"] as! [[String: Any]]
            var transition = records[0]["transition"] as! [String: Any]
            for (name, bytes) in [("before", beforeBytes), ("after", afterBytes)] {
                var observed = transition[name] as! [String: Any]
                observed["observationSHA256"] = FunctionalBytes.digest(bytes)
                observed["expectedSHA256"] = FunctionalBytes.digest(bytes)
                transition[name] = observed
            }
            records[0]["transition"] = transition
            arrays.journal["records"] = records
            if value == "[1]" {
                try collector(arrayPolicy).appendStage(stage(arrays))
            } else {
                #expect(throws: (any Error).self) {
                    try collector(arrayPolicy).appendStage(stage(arrays))
                }
            }
        }
    }

    private func colorHistoryCounterexamples() throws {
        var colors = Self()
        colors.owner = "colorPicker"
        let colorPolicy = Evidence.Policy(
            definition: colors.policy.definition,
            semantics: colors.policy.semantics.map {
                let rule = Evidence.SemanticRule.object([
                    "preferencesSHA256": .object(["maskedSHA256": .sha256])
                ])
                return .init(
                    phase: $0.phase, before: rule, after: rule,
                    savedBefore: $0.savedBefore, savedAfter: $0.savedAfter,
                    relation: .colorPickerHistory)
            })
        func swatch(_ id: Int, red: Double = 0.25) -> [String: Any] {
            [
                "id": identifier(id).uppercased(), "red": red, "green": 0.5,
                "blue": 0.75, "profile": "sRGB", "pickedAt": 100.0,
            ]
        }
        func preferences(
            _ history: [[String: Any]], limit: Any = 3,
            untouched: Any = "synthetic"
        ) throws -> Data {
            let data = try FunctionalBytes.canonical(history)
            return try PropertyListSerialization.data(
                fromPropertyList: [
                    "colorPickerHistory": data, "colorPickerHistorySize": limit,
                    "colorPickerProfile": "sRGB", "untouched": untouched,
                ], format: .binary, options: 0)
        }
        let initial = [swatch(700), swatch(701)]
        for limit in [1, 2, 3, 100] {
            let beforeHistory = Array(initial.prefix(limit))
            let after = Array(([swatch(702)] + beforeHistory).prefix(limit))
            let beforePrefs = try preferences(beforeHistory, limit: limit)
            let afterPrefs = try preferences(after, limit: limit)
            var fixture = try colors.fixture(0)
            fixture.colorPreferences = [beforePrefs, afterPrefs, beforePrefs, afterPrefs]
            try bindColorObservations(&fixture)
            try colors.collector(colorPolicy).appendStage(colors.stage(fixture))
        }
        let threePhases = try colors.collector(colorPolicy)
        var retainedHistory = initial
        for phase in 0..<3 {
            let next = Array(([swatch(702 + phase)] + retainedHistory).prefix(3))
            let beforePrefs = try preferences(retainedHistory)
            let afterPrefs = try preferences(next)
            var fixture = try colors.fixture(phase)
            fixture.colorPreferences = [beforePrefs, afterPrefs, beforePrefs, afterPrefs]
            try bindColorObservations(&fixture)
            try threePhases.appendStage(colors.stage(fixture))
            retainedHistory = next
        }
        let complete = try threePhases.finish(
            removal: colors.removal(), sentinels: colors.sentinels())
        #expect(complete.journalPayloads.count == 3)
        for mode in 0..<11 {
            let beforePrefs = try preferences(initial)
            var after = [swatch(702)] + initial
            var providerAfter: Data?
            var limit: Any = 3
            var untouched: Any = "synthetic"
            switch mode {
            case 0: after[1] = swatch(799)
            case 1: after[1] = after[0]
            case 2: providerAfter = try preferences([swatch(703)] + initial)
            case 3: after[0] = swatch(702, red: 0.26)
            case 4: after[0]["profile"] = "displayP3"
            case 5: after[0] = initial[0]
            case 6: after.removeLast()
            case 7: untouched = "changed"
            case 8: limit = true
            case 9: after[0]["red"] = "0.25"
            default: after[1]["pickedAt"] = 101.0
            }
            let afterPrefs = try preferences(after, limit: limit, untouched: untouched)
            var fixture = try colors.fixture(0)
            fixture.colorPreferences = [
                beforePrefs, providerAfter ?? afterPrefs, beforePrefs, afterPrefs,
            ]
            try bindColorObservations(&fixture)
            #expect(throws: (any Error).self) {
                try colors.collector(colorPolicy).appendStage(colors.stage(fixture))
            }
        }
        let beforePrefs = try preferences(initial)
        let afterPrefs = try preferences([swatch(702)] + initial)
        var missing = try colors.fixture(0)
        missing.colorPreferences = [beforePrefs, afterPrefs, beforePrefs, afterPrefs]
        try bindColorObservations(&missing)
        missing.colorPreferences = []
        #expect(throws: (any Error).self) {
            try colors.collector(colorPolicy).appendStage(colors.stage(missing))
        }
        var foreign = try fixture(0)
        foreign.colorPreferences = [beforePrefs, afterPrefs, beforePrefs, afterPrefs]
        #expect(throws: (any Error).self) { try collector().appendStage(stage(foreign)) }
        for invalid in [try preferences([]), try preferences(initial, limit: 1)] {
            #expect(throws: (any Error).self) {
                try Evidence.colorPickerHistoryObservation(preferences: invalid)
            }
        }
        let beforeTyped = try preferences(initial, untouched: 1)
        let afterTyped = try preferences([swatch(702)] + initial, untouched: true)
        var typedChange = try colors.fixture(0)
        typedChange.colorPreferences = [beforeTyped, afterTyped, beforeTyped, afterTyped]
        try bindColorObservations(&typedChange)
        #expect(throws: (any Error).self) {
            try colors.collector(colorPolicy).appendStage(colors.stage(typedChange))
        }
    }

    private func bindColorObservations(_ fixture: inout Fixture) throws {
        func normalized(_ bytes: Data) throws -> Data {
            try FunctionalBytes.canonical([
                "preferencesSHA256": [
                    "maskedSHA256": FunctionalBytes.digest(Data(bytes.base64EncodedString().utf8))
                ]
            ])
        }
        let before = try normalized(fixture.colorPreferences[0])
        let after = try normalized(fixture.colorPreferences[1])
        fixture.before = .init(
            observationID: fixture.before.observationID,
            sequence: fixture.before.sequence, bytes: before)
        fixture.after = .init(
            observationID: fixture.after.observationID,
            sequence: fixture.after.sequence, bytes: after)
        fixture.authoritative = .init(
            observationID: fixture.authoritative.observationID,
            sequence: fixture.authoritative.sequence, bytes: after)
        var records = fixture.journal["records"] as! [[String: Any]]
        var transition = records[0]["transition"] as! [String: Any]
        for (name, bytes) in [("before", before), ("after", after)] {
            var observed = transition[name] as! [String: Any]
            observed["observationSHA256"] = FunctionalBytes.digest(bytes)
            observed["expectedSHA256"] = FunctionalBytes.digest(bytes)
            transition[name] = observed
        }
        records[0]["transition"] = transition
        fixture.journal["records"] = records
    }

    @Test func rejectsBaselineLoadAckAndPersistenceOrder() throws {
        for (key, value) in [("loadSequence", 1), ("sealedThroughSequence", 6)] {
            var fixture = try fixture(0)
            fixture.journal[key] = value
            #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
        }
        var fixture = try fixture(0)
        fixture.persistence = .init(
            name: fixture.persistence.name, readbackSHA256: fixture.persistence.readbackSHA256,
            expectedSHA256: fixture.persistence.expectedSHA256, beforeActivation: nil, sequence: 5)
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
    }

    @Test func rejectsReusedBirthsAndPresentation() throws {
        let collector = try collector()
        try collector.appendStage(stage(fixture(0)))
        var fixture = try fixture(1)
        let prior = try self.fixture(0)
        fixture.capability["engine"] = prior.capability["engine"]
        #expect(throws: (any Error).self) { try collector.appendStage(stage(fixture)) }
        let second = try self.collector()
        try second.appendStage(stage(self.fixture(0)))
        fixture = try self.fixture(1)
        fixture.presentationID = prior.presentationID
        #expect(throws: (any Error).self) { try second.appendStage(stage(fixture)) }
    }

    @Test func rejectsFalseAdmissionForcedStopAndUnreleasedLeases() throws {
        let normallyCompleted = try self.fixture(0)
        #expect(normallyCompleted.joined.isEmpty)
        try collector().appendStage(stage(normallyCompleted))
        let completedToken = normallyCompleted.requestRecords[0].token
        for mode in 0..<7 {
            var retiring = normallyCompleted
            switch mode {
            case 0: retiring.cancelled = [completedToken]
            case 1: retiring.retirementRequested = [completedToken]
            case 2: retiring.joined = [completedToken]
            case 3:
                retiring.cancelled = [identifier(999)]
                retiring.joined = [identifier(999)]
            case 4:
                retiring.cancelled = [completedToken, completedToken]
                retiring.joined = [completedToken]
            case 5:
                retiring.retirementRequested = [completedToken, completedToken]
                retiring.joined = [completedToken]
            default:
                retiring.cancelled = [completedToken]
                retiring.joined = [completedToken, completedToken]
            }
            #expect(throws: (any Error).self) { try collector().appendStage(stage(retiring)) }
        }
        for mode in 0..<2 {
            var retiring = normallyCompleted
            if mode == 0 {
                retiring.cancelled = [completedToken]
            } else {
                retiring.retirementRequested = [completedToken]
            }
            retiring.joined = [completedToken]
            try collector().appendStage(stage(retiring))
        }
        var pending = normallyCompleted
        let pendingToken = identifier(99)
        for event in normallyCompleted.requestRecords.prefix(2) {
            pending.requestRecords.append(
                .init(
                    ordinal: pending.requestRecords.count, event: event.event, token: pendingToken,
                    operation: event.operation, presentationID: event.presentationID,
                    payloadSHA256: event.payloadSHA256, responseSHA256: nil,
                    caller: event.caller, outcome: nil))
        }
        #expect(throws: (any Error).self) { try collector().appendStage(stage(pending)) }
        pending.joined = [pendingToken]
        try collector().appendStage(stage(pending))
        pending.requestRecords.removeLast()
        #expect(throws: (any Error).self) { try collector().appendStage(stage(pending)) }
        var fixture = try fixture(0)
        fixture.admission = .init(
            heldRootPinned: true, heldDescriptorPinned: true, sourceClean: false,
            sourcePinned: true,
            payloadSignatureVerified: true, architectureVerified: true, hostABIVerified: true,
            originalFactoryUnchanged: true, originalControlsUnchanged: true,
            staleGenerationRejected: true)
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
        fixture = try self.fixture(0)
        let stop = fixture.engineStop
        fixture.engineStop = .init(
            stop: stop.stop, preparation: stop.preparation, worker: stop.worker,
            observedBirths: stop.observedBirths, absentBirths: stop.absentBirths,
            terminationStatus: 0, terminationReason: 1, signalAttempts: [15],
            sequence: stop.sequence)
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
        fixture = try self.fixture(0)
        fixture.releasedLeases = []
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
    }

    @Test func rejectsRemovalAndSentinelMismatch() throws {
        #expect(throws: (any Error).self) {
            try completed().finish(removal: removal(leasesReleased: false), sentinels: sentinels())
        }
        #expect(throws: (any Error).self) {
            try completed().finish(
                removal: removal(finalVersions: ["1.1.0"]), sentinels: sentinels())
        }
        #expect(throws: (any Error).self) {
            try completed().finish(
                removal: removal(), sentinels: sentinels(after: Data("changed".utf8)))
        }
    }

    @Test func rejectsIncompleteNativeStopFieldsets() throws {
        for invalidation in [
            Evidence.Invalidation(site: "retired-process-release", peer: nil, peerWasRunning: true),
            Evidence.Invalidation(
                site: "unexpected-live-invalidation", peer: nil, peerWasRunning: false),
        ] {
            var fixture = try fixture(0)
            let native = fixture.nativeStop
            fixture.nativeStop = .init(
                stop: native.stop, ui: native.ui, engine: native.engine,
                observedBirths: native.observedBirths, absentBirths: native.absentBirths,
                signalAttempts: [], joinedTasks: native.joinedTasks, invalidations: [invalidation],
                sequence: native.sequence)
            #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
        }
        var fixture = try fixture(0)
        let native = fixture.nativeStop
        fixture.nativeStop = .init(
            stop: native.stop, ui: native.ui, engine: native.engine,
            observedBirths: native.observedBirths, absentBirths: [], signalAttempts: [],
            joinedTasks: native.joinedTasks, invalidations: native.invalidations,
            sequence: native.sequence)
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
        fixture = try self.fixture(0)
        fixture.nativeStop = .init(
            stop: native.stop, ui: native.ui, engine: native.engine,
            observedBirths: native.observedBirths, absentBirths: native.absentBirths,
            signalAttempts: [],
            joinedTasks: [], invalidations: native.invalidations, sequence: native.sequence)
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
    }

    @Test func enforcesLiteralNumericTypesAndExportBoundary() throws {
        let numericPolicy = Evidence.Policy(
            definition: policy.definition,
            semantics: policy.semantics.map {
                .init(
                    phase: $0.phase, before: $0.before,
                    after: .object(["exportSeconds": .number(minimum: 0, maximum: 30)]),
                    savedBefore: $0.savedBefore, savedAfter: $0.savedAfter, relation: $0.relation)
            })
        for seconds: Any in [30.0, 30.001, true, "30"] {
            var fixture = try fixture(0)
            let bytes = try FunctionalBytes.canonical(["exportSeconds": seconds])
            let hash = FunctionalBytes.digest(bytes)
            fixture.after = .init(
                observationID: fixture.after.observationID, sequence: fixture.after.sequence,
                bytes: bytes)
            fixture.authoritative = .init(
                observationID: fixture.authoritative.observationID,
                sequence: fixture.authoritative.sequence, bytes: bytes)
            var records = fixture.journal["records"] as! [[String: Any]]
            var transition = records[0]["transition"] as! [String: Any]
            var after = transition["after"] as! [String: Any]
            after["observationSHA256"] = hash
            after["expectedSHA256"] = hash
            transition["after"] = after
            records[0]["transition"] = transition
            fixture.journal["records"] = records
            if let number = seconds as? Double, number == 30 {
                try collector(numericPolicy).appendStage(stage(fixture))
            } else {
                #expect(throws: (any Error).self) {
                    try collector(numericPolicy).appendStage(stage(fixture))
                }
            }
        }
    }

    @Test func rejectsUnsafeSequencesCrossSourceAndLostPersistence() throws {
        var fixture = try fixture(0)
        fixture.journal["sealedThroughSequence"] = 9_007_199_254_740_992
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
        fixture = try self.fixture(0)
        fixture.capability["sourceCommit"] = String(repeating: "b", count: 40)
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
        fixture = try self.fixture(0)
        fixture.rawSaved = Data("{\"enabled\":false}".utf8)
        #expect(throws: (any Error).self) { try collector().appendStage(stage(fixture)) }
    }

    @Test func rejectsMissingChangedAndMalformedJournalSeals() throws {
        let unsigned = try completed().finish(removal: removal(), sentinels: sentinels())
        #expect(throws: (any Error).self) { try unsigned.observation(journalEnvelopes: []) }
        let envelopes = unsigned.journalPayloads.map {
            Evidence.JournalEnvelope(
                schema: 1, payload: String(decoding: $0, as: UTF8.self), signature: "invalid")
        }
        #expect(throws: (any Error).self) { try unsigned.observation(journalEnvelopes: envelopes) }
        let changed = unsigned.journalPayloads.map {
            Evidence.JournalEnvelope(
                schema: 1, payload: String(decoding: $0, as: UTF8.self) + " ",
                signature: Data(repeating: 0, count: 64).base64EncodedString())
        }
        #expect(throws: (any Error).self) { try unsigned.observation(journalEnvelopes: changed) }
    }
}
