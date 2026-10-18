import CryptoKit
import Foundation
import FunctionalActionContract
import Testing
@testable import FunctionalProducerModels

struct FunctionalEvidenceSealingTests {
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
        let presentation = try FunctionalEvidenceSealing.presentationID(
            FunctionalBytes.canonical(cap))
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

    private func unsigned() throws -> Evidence.UnsignedEvidence {
        try completed().finish(removal: removal(), sentinels: sentinels())
    }

    private func envelope(_ payload: Data, key: Curve25519.Signing.PrivateKey) throws -> Data {
        try FunctionalBytes.canonical([
            "schema": 1, "payload": String(decoding: payload, as: UTF8.self),
            "signature": try key.signature(for: payload).base64EncodedString(),
        ])
    }

    private func presentationInputs() throws -> (
        Evidence.CompletedStage, Data, [FunctionalEvidenceSealing.StepInventory], Data
    ) {
        let stage = try stage(fixture(0))
        let collector = try collector()
        try collector.appendStage(stage)
        let cap = stage.capability
        var inventory: [String: Any] = [
            "sourceCommit": source, "factoryOverlay": false, "hostABI": cap.hostABI,
            "version": cap.version, "packageSHA256": cap.packageSHA256,
            "bundleTreeSHA256": String(repeating: "c", count: 64),
            "engine": try FunctionalBytes.object(encode(cap.engine)),
            "ui": try FunctionalBytes.object(encode(cap.ui)),
            "presentationID": stage.presentationID,
        ]
        for field in [
            "sourceClean", "heldRootPinned", "heldDescriptorPinned", "hostSignatureVerified",
            "workerSignatureVerified", "roleSignatureVerified", "rolePayloadUnchanged",
            "originalFactoriesUnchanged", "originalControlsUnchanged",
        ] { inventory[field] = true }
        let data = try FunctionalBytes.canonical(inventory)
        let recipe = try FunctionalBytes.canonical([
            "schema": 1, "owner": owner, "location": "main", "section": owner,
            "operation": try #require(cap.activationOperation),
            "steps": [
                ["role": "button", "label": "Open control", "action": "click", "value": NSNull()],
                ["role": "toggle", "label": "Toggle awake", "action": "click", "value": NSNull()],
            ],
            "sources": [
                try FunctionalBytes.object(encode(policy.definition.activation.sources[0]))
            ],
        ])
        let inventories = [0, 1].map {
            FunctionalEvidenceSealing.StepInventory(index: $0, beforeData: data, afterData: data)
        }
        let drain = try FunctionalBytes.canonical([
            "births": [
                try FunctionalBytes.object(encode(cap.engine)),
                try FunctionalBytes.object(encode(cap.ui)),
            ],
            "allTasksJoined": true, "birthsAbsent": true, "leasesReleased": true, "signalsSent": 0,
        ])
        return (stage, recipe, inventories, drain)
    }

    @Test func preservesOriginalClaimJournalsAndObservationWithSuppliedIssuer() throws {
        let unsigned = try unsigned()
        let key = Curve25519.Signing.PrivateKey()
        var payloads: [Data] = []
        let proof = try FunctionalEvidenceSealing.sealOwner(
            evidence: unsigned, owner: owner,
            caseSHA256: FunctionalBytes.digest(encode(policy.definition)),
            publicKey: key.publicKey.rawRepresentation,
            sign: { payload in
                payloads.append(payload); return try envelope(payload, key: key)
            })
        #expect(payloads.count == 5)
        #expect(payloads[0] == (try FunctionalBytes.canonical(unsigned.claim)))
        #expect(Array(payloads[1...3]) == unsigned.journalPayloads)
        let sealedClaim = try FunctionalBytes.object(proof.claimData)
        #expect(Data((sealedClaim["payload"] as! String).utf8) == payloads[0])
        let sealedObservation = try FunctionalBytes.object(proof.observationData)
        let observation = try FunctionalBytes.object(
            Data((sealedObservation["payload"] as! String).utf8))
        let stages = observation["stages"] as! [[String: Any]]
        for (index, value) in stages.enumerated() {
            let journal = try FunctionalBytes.canonical(value["mutationJournal"]!)
            let verified = try HostedFunctionalMutationJournal.verify(
                journal, issuerKey: key.publicKey.rawRepresentation)
            #expect(try encode(verified) == unsigned.journalPayloads[index])
        }
        #expect(proof.owner == owner)
        #expect(proof.caseSHA256 == FunctionalBytes.digest(try encode(policy.definition)))
    }

    @Test func rejectsWrongIssuerChangedPayloadAndMalformedSignature() throws {
        let unsigned = try unsigned()
        let key = Curve25519.Signing.PrivateKey()
        let foreign = Curve25519.Signing.PrivateKey()
        let hash = FunctionalBytes.digest(try encode(policy.definition))
        #expect(throws: (any Error).self) {
            try FunctionalEvidenceSealing.sealOwner(
                evidence: unsigned, owner: owner, caseSHA256: hash,
                publicKey: key.publicKey.rawRepresentation, sign: { try envelope($0, key: foreign) }
            )
        }
        #expect(throws: (any Error).self) {
            try FunctionalEvidenceSealing.sealOwner(
                evidence: unsigned, owner: owner, caseSHA256: hash,
                publicKey: key.publicKey.rawRepresentation,
                sign: { _ in
                    try envelope(
                        FunctionalBytes.canonical(["schema": 1, "owner": owner]), key: key)
                })
        }
        #expect(throws: (any Error).self) {
            try FunctionalEvidenceSealing.sealOwner(
                evidence: unsigned, owner: owner, caseSHA256: hash,
                publicKey: key.publicKey.rawRepresentation,
                sign: { _ in Data(repeating: 0, count: 64) })
        }
    }

    @Test func emitsExactPresentationWithEveryOriginalRecipeInventory() throws {
        let (stage, recipe, inventories, drain) = try presentationInputs()
        let bytes = try FunctionalEvidenceSealing.presentation(
            stage: stage, recipe: recipe,
            definition: encode(policy.definition), inventories: inventories, drainReceipt: drain)
        let document = try FunctionalBytes.object(bytes)
        #expect(
            Set(document.keys) == [
                "schema", "authority", "execution", "capabilitySHA256", "recipeSHA256",
                "presentationID", "windowTitle", "before", "after", "steps", "stepInventories",
                "mutation", "authoritative", "presentationClosed", "leasesReleased",
            ])
        let captured = document["stepInventories"] as! [[String: Any]]
        #expect(captured.map { $0["index"] as! Int } == [0, 1])
        #expect(
            try FunctionalBytes.canonical(document["steps"]!)
                == FunctionalBytes.canonical(FunctionalBytes.object(recipe)["steps"]!))
        let authoritative = document["authoritative"] as! [String: Any]
        #expect(authoritative["kind"] as? String == policy.definition.observation.kind)
        #expect(authoritative["name"] as? String == policy.definition.observation.name)
    }

    @Test func rejectsReindexedInventoryForeignDefinitionAndFalseDrain() throws {
        let (stage, recipe, inventories, drain) = try presentationInputs()
        let reindexed = [
            inventories[0],
            FunctionalEvidenceSealing.StepInventory(
                index: 2, beforeData: inventories[1].beforeData, afterData: inventories[1].afterData
            ),
        ]
        #expect(throws: (any Error).self) {
            try FunctionalEvidenceSealing.presentation(
                stage: stage, recipe: recipe, definition: encode(policy.definition),
                inventories: reindexed, drainReceipt: drain)
        }
        var definition = try FunctionalBytes.object(encode(policy.definition))
        definition["observation"] = ["kind": "checked-engine-readback", "name": "foreign-state"]
        #expect(throws: (any Error).self) {
            try FunctionalEvidenceSealing.presentation(
                stage: stage, recipe: recipe, definition: FunctionalBytes.canonical(definition),
                inventories: inventories, drainReceipt: drain)
        }
        var changed = try FunctionalBytes.object(drain)
        changed["leasesReleased"] = false
        #expect(throws: (any Error).self) {
            try FunctionalEvidenceSealing.presentation(
                stage: stage, recipe: recipe, definition: encode(policy.definition),
                inventories: inventories, drainReceipt: FunctionalBytes.canonical(changed))
        }
        var falseInventory = try FunctionalBytes.object(inventories[1].afterData)
        falseInventory["workerSignatureVerified"] = false
        let falseInputs = [
            inventories[0],
            FunctionalEvidenceSealing.StepInventory(
                index: 1, beforeData: inventories[1].beforeData,
                afterData: try FunctionalBytes.canonical(falseInventory)),
        ]
        #expect(throws: (any Error).self) {
            try FunctionalEvidenceSealing.presentation(
                stage: stage, recipe: recipe, definition: encode(policy.definition),
                inventories: falseInputs, drainReceipt: drain)
        }
    }

    @Test func rejectsIncompleteOwnerSetRatherThanProducingQualifiedSuccess() throws {
        let key = Curve25519.Signing.PrivateKey()
        let root = "/synthetic/functional-fixture-" + session
        let hash = String(repeating: "a", count: 64)
        let context = FunctionalEvidenceSealing.QualifiedContext(
            schema: 1, sourceCommit: source,
            mergeCommit: String(repeating: "b", count: 40),
            baseCommit: String(repeating: "c", count: 40),
            session: session, root: root,
            hostIdentifier: "com.pulkit.edith.tests.worker-" + session,
            issuerPublicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            issuerManifestSHA256: hash,
            artifactSHA256: hash, policySHA256: hash, sourceSHA256: hash, toolchainSHA256: hash,
            runID: 1, jobID: 2, runAttempt: 1, workflowSHA256: hash,
            producer: .init(
                pid: 901, birthSeconds: 100, birthMicroseconds: 10, uid: uid,
                executable: root + "/Producer/functional-producer", executableSHA256: hash),
            host: .init(
                pid: 902, birthSeconds: 100, birthMicroseconds: 11, uid: uid,
                executable: root + "/Fixture.app/Contents/MacOS/Edith", executableSHA256: hash))
        let proof = try FunctionalEvidenceSealing.sealOwner(
            evidence: unsigned(), owner: owner,
            caseSHA256: FunctionalBytes.digest(encode(policy.definition)),
            publicKey: key.publicKey.rawRepresentation,
            sign: { try envelope($0, key: key) })
        #expect(throws: (any Error).self) {
            try FunctionalEvidenceSealing.aggregate(
                context: context, owners: [proof],
                retirement: .init(hostAbsent: true, receiverJoined: true, signalsSent: 0),
                publicKey: key.publicKey.rawRepresentation)
        }
        #expect(throws: (any Error).self) {
            try FunctionalEvidenceSealing.aggregate(
                context: context, owners: [],
                retirement: .init(hostAbsent: false, receiverJoined: false, signalsSent: 9),
                publicKey: key.publicKey.rawRepresentation)
        }
    }
}
