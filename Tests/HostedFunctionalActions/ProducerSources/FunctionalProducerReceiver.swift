import Darwin
import Foundation
import ExtensionMarketplace
import WorkerFixtureSupport

@MainActor
final class FunctionalProducerReceiver {
    private let root: FunctionalPinnedPath
    private let issuer: FunctionalIssuer
    private let producer: FunctionalBirth
    private let bridge: FunctionalHostBridge
    private var originalRead: FunctionalOriginalReadObservation?
    private var stepReadbacks:
        [(
            index: Int, before: FunctionalOriginalReadObservation,
            after: FunctionalOriginalReadObservation
        )] = []
    private var beforeStepRead: FunctionalOriginalReadObservation?
    private var beforeStepInventory: [String: Any]?
    private var stepInventories: [[String: Any]] = []
    private var completedStages: [String: [FunctionalCollectedEvidence.CompletedStage]] = [:]
    private var collectors: [String: FunctionalCollectedEvidence] = [:]
    private var ownerProofs: [String: FunctionalEvidenceSealing.OwnerProof] = [:]
    private var presentationClaims: [String: [String: Data]] = [:]
    private var originalUIReceiptClaims: [String: [String: Data]] = [:]
    private var beforeStepRaw: FunctionalOwnerSavedReader.RawObservation?
    private var stepRawSnapshots:
        [(
            index: Int, before: FunctionalOwnerSavedReader.RawObservation,
            after: FunctionalOwnerSavedReader.RawObservation
        )] = []
    private var admissionFacts: FunctionalCollectedEvidence.AdmissionFacts?
    private var retiredBirths: [String: [FunctionalBirth]] = [:]
    private var finalAuthoritativeRead: FunctionalOriginalReadObservation?
    private var capturedLeases: [(token: String, file: FunctionalPinnedPath)] = []
    private var releasedLeaseTokens: [String] = []
    private var host: FunctionalBirth?
    private var reservation: FunctionalGenerationReservation?
    private var socket: FunctionalHostSocket?
    private var held: FunctionalHeldPresentation?
    private var journal: FunctionalRequestJournal?
    private var requestIDs = Set<String>()
    private let requestLimit: Int
    private var xctestActor: FunctionalXCTestActor?
    private var savedGeneration: FunctionalSavedGeneration?
    private var finalSavedObservations: [String: FunctionalOwnerSavedReader.RawObservation] = [:]
    private var observationSequence = 0
    private var preservedSaved:
        [String: (
            reader: FunctionalOwnerSavedReader,
            observation: FunctionalOwnerSavedReader.RawObservation
        )] = [:]
    private var drainClaim: Data?
    private var removalClaims: [String: [Data]] = [:]
    private var closed = false

    init(
        root: FunctionalPinnedPath, issuer: FunctionalIssuer, producer: FunctionalBirth,
        bridge: FunctionalHostBridge
    ) throws {
        self.root = root
        self.issuer = issuer
        self.producer = producer
        self.bridge = bridge
        requestLimit = try HostedFunctionalActionContext.owners.reduce(0) { total, owner in
            guard let recipe = FunctionalProducerBuild.recipes[owner],
                let steps = try FunctionalBytes.object(recipe)["steps"] as? [[String: Any]],
                !steps.isEmpty, steps.count <= 16
            else { throw FunctionalFailure.invalid("compiled receiver message budget") }
            return total + 3
                * (4096 + steps.count * 6 + 2 + 6
                    * FunctionalGenerationReservation.notificationLimit
                    + FunctionalGenerationReservation.operations.count + 1)
        }
        try root.requireCurrent()
        try producer.requireCurrent()
        socket = try FunctionalHostSocket(root: root, endpoint: .producer) {
            [weak self] caller, message in
            guard let self else { throw FunctionalFailure.invalid("released producer receiver") }
            return try await self.receive(caller, message)
        }
    }

    func requireHealthy() throws {
        guard !closed, let socket else {
            throw FunctionalFailure.invalid("closed producer receiver")
        }
        try root.requireCurrent()
        try producer.requireCurrent()
        try socket.requireHealthy()
    }

    func bindHost(_ value: FunctionalBirth) throws {
        try requireHealthy()
        guard host == nil, reservation == nil, held == nil,
            value.executable == root.url.path + "/Fixture.app/Contents/MacOS/Edith"
        else { throw FunctionalFailure.invalid("source-bound original Host binding") }
        try FunctionalHeldPresentation.signer(identifier: FunctionalProducerBuild.hostIdentifier)
            .verify(root.url.appendingPathComponent("Fixture.app"), birth: value)
        host = value
    }

    func captureBeforeConstruction(owner: String, phase: String) async throws -> Data {
        try requireHealthy()
        guard host != nil, reservation == nil, held == nil, journal == nil, savedGeneration == nil,
            let policy = FunctionalProducerBuild.rolePolicies.first(where: { $0.owner == owner }),
            let definition = FunctionalProducerBuild.savedReaderPolicies[owner],
            let preparation = FunctionalProducerBuild.preparationPolicies[owner],
            let filePhase = WorkerFixtureFilePhase(rawValue: phase)
        else { throw FunctionalFailure.invalid("source-owned early saved observation order") }
        let savedDefinition = try FunctionalBytes.object(definition, maximum: 262_144)
        if let reads = savedDefinition["reads"] as? [Any],
            let sentinels = savedDefinition["sentinels"] as? [Any],
            reads.isEmpty, sentinels.isEmpty
        {
            guard ["calendar", "audioMixer"].contains(owner), savedDefinition["initial"] is NSNull,
                savedDefinition["final"] is NSNull,
                policy.fileScopes.allSatisfy({
                    $0.purpose == .immutableInput && $0.mutableFiles.isEmpty
                }),
                policy.outputs.isEmpty
            else {
                throw FunctionalFailure.invalid(
                    "stateless original source with mutable file grants")
            }
        }
        if phase != "initial" {
            guard finalSavedObservations[owner] != nil else {
                throw FunctionalFailure.invalid("missing prior actual saved generation")
            }
        }
        if phase == "initial" || owner == "blitztree" {
            let files = try FunctionalFileScopes.preparationFiles(
                owner: owner, root: root.url.path, session: issuer.session, policy: policy,
                bytes: preparation, phase: filePhase)
            try FunctionalSavedGeneration.prepareDirectories(
                owner: owner, phase: filePhase, root: root,
                issuer: issuer, policy: policy, definition: definition)
            try FunctionalFileScopes.prepare(files, root: root)
            if owner == "timeLapse" {
                _ = try await FunctionalSyntheticMedia.createTimeLapse(
                    root: root, sourceCommit: issuer.sourceCommit, session: issuer.session)
            } else if owner == "studio" {
                _ = try await FunctionalSyntheticMedia.createStudioSource(
                    root: root, sourceCommit: issuer.sourceCommit,
                    session: issuer.session, policy: policy)
            } else if owner == "downloads" {
                _ = try await FunctionalSyntheticMedia.createDownloadsAudio(
                    root: root, sourceCommit: issuer.sourceCommit,
                    session: issuer.session, policy: policy)
            }
        }
        observationSequence += 1
        let saved = try FunctionalSavedGeneration(
            owner: owner, phase: phase, root: root, issuer: issuer,
            definition: definition, sequence: observationSequence,
            previous: finalSavedObservations[owner])
        savedGeneration = saved
        return try issuer.seal(saved.baselineClaim)
    }

    func readSaved(owner: String, phase: String) async throws -> Data {
        try requireHealthy()
        guard let held, held.capability.owner == owner, held.capability.phase == phase,
            let savedGeneration, savedGeneration.owner == owner, savedGeneration.phase == phase
        else {
            throw FunctionalFailure.invalid("actual saved read generation binding")
        }
        try xctestActor?.requireFinished()
        finalAuthoritativeRead = try await readOriginalState(held: held)
        observationSequence += 1
        return try issuer.seal(savedGeneration.readSaved(sequence: observationSequence, held: held))
    }

    func originalUIReceipt(owner: String, phase: String) throws -> Data {
        try requireHealthy()
        guard owner == "calendar", let held, held.capability.owner == owner,
            held.capability.phase == phase,
            let actor = xctestActor, let recipe = FunctionalProducerBuild.recipes[owner],
            originalUIReceiptClaims[owner]?[phase] == nil, stepReadbacks.count == 1,
            stepReadbacks[0].index == 0, let before = stepReadbacks[0].before.bytes,
            let after = stepReadbacks[0].after.bytes
        else {
            throw FunctionalFailure.invalid("missing actual original local UI receipt")
        }
        try held.requireCurrent()
        let control = try actor.observedCalendarControl()
        let observations = try actor.observations()
        guard let steps = observations["steps"] as? [[String: Any]], steps.count == 1,
            let authorization = steps[0]["authorization"] as? [String: Any],
            let completion = steps[0]["completion"] as? [String: Any]
        else {
            throw FunctionalFailure.invalid("missing actual signed actor UI boundary")
        }
        let signed = try issuer.seal([
            "schema": 1, "kind": "original-calendar-local-control",
            "sourceCommit": issuer.sourceCommit, "session": issuer.session, "owner": owner,
            "phase": phase,
            "caseSHA256": held.capability.caseSHA256, "presentationID": held.presentationID,
            "capabilitySHA256": held.capabilitySHA256,
            "recipeSHA256": FunctionalBytes.digest(recipe),
            "authorization": authorization, "completion": completion,
            "beforeBackend": before.base64EncodedString(),
            "afterBackend": after.base64EncodedString(),
            "beforeControl": control.before.bytes.base64EncodedString(),
            "afterControl": control.after.bytes.base64EncodedString(),
        ])
        _ = try HostedFunctionalOriginalUIReceipt.verify(
            signedBytes: signed, issuerKey: issuer.publicKey,
            context: held.capability, presentationID: held.presentationID,
            capabilitySHA256: held.capabilitySHA256, recipeSHA256: FunctionalBytes.digest(recipe))
        try held.requireCurrent()
        originalUIReceiptClaims[owner, default: [:]][phase] = signed
        return signed
    }

    func prepareGeneration(owner: String, phase: String) throws -> [String: Any] {
        try requireHealthy()
        guard let host, reservation == nil, held == nil, journal == nil,
            savedGeneration?.owner == owner, savedGeneration?.phase == phase
        else {
            throw FunctionalFailure.invalid("source-owned generation preparation order")
        }
        let next = try FunctionalGenerationReservation(
            owner: owner, phase: phase, root: root,
            issuer: issuer, producer: producer, host: host)
        reservation = next
        return next.presentationRequest
    }

    func presentationReturned(owner: String, response: [String: Any]) throws {
        guard let reservation, reservation.owner == owner else {
            throw FunctionalFailure.invalid("unreserved original presentation response")
        }
        try reservation.presentationReturned(response)
    }

    func heldGeneration(owner: String, phase: String) async throws -> FunctionalHeldPresentation {
        try requireHealthy()
        guard let reservation, reservation.owner == owner, reservation.phase == phase,
            reservation.stage == .granted, reservation.isPresented, let held,
            held === reservation.held
        else {
            throw FunctionalFailure.invalid("original generation not admitted before construction")
        }
        try held.requireCurrent()
        if capturedLeases.isEmpty { try captureHeldLease(held) }
        if admissionFacts == nil {
            admissionFacts = try await held.evidenceAdmission(
                descriptors: reservation.currentDescriptors(),
                retired: retiredBirths[owner, default: []], issuer: issuer)
        }
        guard let savedGeneration else {
            throw FunctionalFailure.invalid("missing early actual saved observation")
        }
        if savedGeneration.persistence.loadSequence == nil {
            observationSequence += 1
            try savedGeneration.bindLoaded(held: held, sequence: observationSequence)
        }
        return held
    }

    func hold(_ value: FunctionalHeldPresentation) throws {
        try requireHealthy()
        guard held == nil, journal == nil else {
            throw FunctionalFailure.invalid("active original receiver generation")
        }
        let next = try FunctionalRequestJournal(held: value)
        held = value
        journal = next
    }

    func registerXCTestActor(held: FunctionalHeldPresentation, artifact: [String: Any]) throws
        -> [String: Any]
    {
        try requireHealthy()
        guard self.held === held, xctestActor == nil || xctestActor?.completed == true else {
            throw FunctionalFailure.invalid("overlapping original XCTest actors")
        }
        try xctestActor?.requireFinished()
        let actor = try FunctionalXCTestActor(
            held: held, artifact: artifact, root: root, issuer: issuer)
        xctestActor = actor
        return [
            "owner": held.capability.owner, "phase": held.capability.phase,
            "presentationID": held.presentationID, "capabilitySHA256": held.capabilitySHA256,
            "recipeSHA256": actor.recipeSHA256, "sourceSHA256": actor.sourceSHA256,
            "invocationPath": actor.invocationPath, "stepCount": actor.stepCount,
        ]
    }

    func xctestStepObservations(held: FunctionalHeldPresentation) throws -> [String: Any] {
        try requireHealthy()
        guard self.held === held, let actor = xctestActor else {
            throw FunctionalFailure.invalid("missing actual XCTest actor observations")
        }
        return try actor.observations()
    }

    func retire(_ value: FunctionalHeldPresentation) throws {
        try requireHealthy()
        guard held === value, let journal,
            presentationClaims[value.capability.owner]?[value.capability.phase] != nil
        else { throw FunctionalFailure.invalid("unheld original receiver generation") }
        guard let reservation, reservation.held === value else {
            throw FunctionalFailure.invalid("retirement without original reservation")
        }
        try xctestActor?.requireFinished()
        try value.requireCompletedOriginalSteps()
        try reservation.requireDrained(journal: journal)
        guard let savedGeneration, let final = savedGeneration.finalObservation else {
            throw FunctionalFailure.invalid("missing final saved observation before retirement")
        }
        try savedGeneration.reader.requirePreserved(since: final)
        retiredBirths[value.capability.owner, default: []].append(contentsOf: [
            value.engine, value.ui,
        ])
        finalSavedObservations[value.capability.owner] = final
        preservedSaved[value.capability.owner] = (savedGeneration.reader, final)
        self.savedGeneration = nil
        self.journal = nil
        xctestActor = nil
        held = nil
        self.reservation = nil
        drainClaim = nil
        beforeStepRead = nil
        beforeStepInventory = nil
        stepInventories.removeAll()
        stepReadbacks.removeAll()
        stepRawSnapshots.removeAll()
        beforeStepRaw = nil
        finalAuthoritativeRead = nil
        admissionFacts = nil
        capturedLeases.removeAll()
        releasedLeaseTokens.removeAll()
    }

    func acceptDrain(owner: String, response: [String: Any]) throws {
        try requireHealthy()
        guard let held, held.capability.owner == owner, let reservation, let journal,
            let savedGeneration,
            savedGeneration.finalObservation != nil, drainClaim == nil,
            let receipt = response["drain"] as? [String: Any]
        else { throw FunctionalFailure.invalid("unobserved original Host drain") }
        try FunctionalBytes.exact(
            receipt,
            ["births", "birthsAbsent", "leasesReleased", "sourceOwnedDrainReceiptRequired"])
        guard let births = receipt["births"] as? [[String: Any]],
            try FunctionalBytes.canonical(births)
                == FunctionalBytes.canonical([held.engine.contractObject, held.ui.contractObject]),
            try FunctionalBytes.boolean(receipt, "birthsAbsent"),
            try FunctionalBytes.boolean(receipt, "leasesReleased"),
            try FunctionalBytes.boolean(receipt, "sourceOwnedDrainReceiptRequired")
        else { throw FunctionalFailure.invalid("source Host drain receipt binding") }
        try xctestActor?.requireFinished()
        try held.requireCompletedOriginalSteps()
        try reservation.requireDrained(journal: journal)
        try releaseCapturedLeases()
        let released = !capturedLeases.isEmpty && releasedLeaseTokens == capturedLeases.map(\.token)
        let collected = try reservation.collectedDrain(leasesReleased: released)
        drainClaim = try issuer.seal([
            "schema": 1, "sourceCommit": issuer.sourceCommit, "session": issuer.session,
            "owner": owner, "phase": held.capability.phase,
            "capabilitySHA256": held.capabilitySHA256, "receipt": collected,
        ])
    }

    func collectedDrain(owner: String, phase: String) throws -> Data {
        try requireHealthy()
        guard let held, held.capability.owner == owner, held.capability.phase == phase,
            let drainClaim,
            reservation?.stage == .drained
        else { throw FunctionalFailure.invalid("missing actual collected drain") }
        try held.engine.requireAbsent()
        try held.ui.requireAbsent()
        return drainClaim
    }

    func collectRemoval(owner: String, response: [String: Any]) throws -> Data {
        try requireHealthy()
        guard held == nil, reservation == nil, savedGeneration == nil,
            let previous = preservedSaved[owner],
            response["removedVersions"] as? [String] == ["1.0.0", "1.1.0"]
        else { throw FunctionalFailure.invalid("source original removal order") }
        let packageRoot = root.url.appendingPathComponent(
            "Edith Tests/worker-" + issuer.session + "/Extensions")
        _ = try FunctionalPinnedPath(packageRoot, directory: true)
        var absent: [String] = []
        for version in ["1.0.0", "1.1.0"] {
            let path = packageRoot.appendingPathComponent(owner + "/edith-host-2/arm64/" + version)
            var state = stat()
            guard path.path == path.resolvingSymlinksInPath().path, lstat(path.path, &state) != 0,
                errno == ENOENT
            else {
                throw FunctionalFailure.invalid("original installed version physically retained")
            }
            absent.append(version)
        }
        let pendingURL = packageRoot.appendingPathComponent("pending-removals.json")
        var pending = Set<String>()
        var state = stat()
        if lstat(pendingURL.path, &state) == 0 {
            let bytes = try FunctionalPinnedPath(pendingURL, directory: false, maximum: 1_048_576)
                .read()
            pending = try JSONDecoder().decode(Set<String>.self, from: bytes)
            guard pending.allSatisfy({ HostedFunctionalActionContext.owners.contains($0) }) else {
                throw FunctionalFailure.invalid("foreign removal record")
            }
        } else {
            guard errno == ENOENT else {
                throw FunctionalFailure.invalid("pending removal observation")
            }
        }
        guard !pending.contains(owner) else {
            throw FunctionalFailure.invalid("original pending removal retained")
        }
        let released = try probePackageLeases(owner: owner)
        try previous.reader.requirePreserved(since: previous.observation)
        let current = try previous.reader.observeSentinels()
        let before = try rawFingerprint(previous.observation)
        let after = try rawFingerprint(current)
        let receipt: [String: Any] = [
            "physicallyAbsentVersions": absent, "pendingRemoval": pending.contains(owner),
            "leasesReleased": released, "sentinelBytesPreserved": before == after,
            "semanticDataPreserved": previous.observation.saved == current.saved,
        ]
        let sealed = try issuer.seal([
            "schema": 1, "sourceCommit": issuer.sourceCommit, "session": issuer.session,
            "owner": owner, "receipt": receipt, "before": previous.observation.object,
            "after": current.object,
        ])
        removalClaims[owner, default: []].append(sealed)
        return sealed
    }

    func sealPresentationProof(owner: String, phase: String) throws -> Data {
        try requireHealthy()
        guard let held, held.capability.owner == owner, held.capability.phase == phase,
            let reservation, reservation.stage == .drained, let journal, let savedGeneration,
            let baseline = savedGeneration.persistence.baseline,
            let loadSequence = savedGeneration.persistence.loadSequence,
            let finalPersistence = savedGeneration.finalPersistence,
            let authoritative = finalAuthoritativeRead,
            let authoritativeBytes = authoritative.normalizedBytes,
            let admissionFacts, let drainClaim, let actor = xctestActor,
            let recipe = FunctionalProducerBuild.recipes[owner],
            let definition = FunctionalProducerBuild.caseDefinitions[owner],
            let policy = FunctionalProducerBuild.evidencePolicies[owner],
            presentationClaims[owner]?[phase] == nil,
            completedStages[owner, default: []].count
                == ["initial", "updated", "reinstalled"].firstIndex(of: phase)
        else { throw FunctionalFailure.invalid("missing actual collected presentation facts") }
        try actor.requireFinished()
        try reservation.requireDrained(journal: journal)
        guard actor.stepCount == stepReadbacks.count, actor.stepCount == stepInventories.count,
            actor.stepCount == stepRawSnapshots.count,
            stepReadbacks.map(\.index) == Array(0..<actor.stepCount),
            stepRawSnapshots.map(\.index) == Array(0..<actor.stepCount),
            let baselineObject = savedGeneration.baselineClaim["baseline"] as? [String: Any]
        else {
            throw FunctionalFailure.invalid("complete source-owned original step captures")
        }
        let binding = admissionFacts.binding
        let drain = try reservation.evidenceDrain(
            binding: binding,
            capturedLeaseTokens: capturedLeases.map(\.token),
            releasedLeaseTokens: releasedLeaseTokens)
        let events = try journal.records.map { record -> FunctionalEvidenceAssembly.RequestFact in
            guard
                let event = FunctionalCollectedEvidence.RequestEvent(
                    rawValue: record.event.rawValue)
            else {
                throw FunctionalFailure.invalid("actual original request event type")
            }
            let caller = try JSONDecoder().decode(
                HostedFunctionalProcessIdentity.self,
                from: FunctionalBytes.canonical(record.caller.contractObject))
            return .init(
                ordinal: record.ordinal, sequence: record.sequence, event: event,
                token: record.token,
                operation: record.operation, presentationID: record.presentationID,
                payloadSHA256: record.payloadSHA256,
                responseSHA256: record.responseSHA256, caller: caller, outcome: record.outcome,
                activationID: record.activationID, stepIndex: record.stepIndex,
                payload: record.payload)
        }
        let starts = try journal.records.filter { record in
            guard record.event == .hostBefore,
                record.operation == held.capability.activationOperation
            else { return false }
            guard let payload = record.payload else {
                throw FunctionalFailure.invalid("missing original request classification payload")
            }
            return try isActivationMutation(
                ["operation": record.operation, "payload": payload.base64EncodedString()],
                held: held)
        }
        let steps = try starts.map { start -> FunctionalEvidenceAssembly.StepFact in
            guard let index = start.stepIndex, let activationID = start.activationID,
                stepReadbacks.indices.contains(index), stepReadbacks[index].index == index,
                let before = stepReadbacks[index].before.normalizedBytes,
                let after = stepReadbacks[index].after.normalizedBytes
            else {
                throw FunctionalFailure.invalid("actual mutation source step raw reads")
            }
            return .init(
                index: index, activationID: activationID,
                before: .init(
                    observationID: stepReadbacks[index].before.observationID,
                    sequence: stepReadbacks[index].before.sequence, bytes: before),
                after: .init(
                    observationID: stepReadbacks[index].after.observationID,
                    sequence: stepReadbacks[index].after.sequence, bytes: after))
        }
        let prior: FunctionalCollectedEvidence.PriorPersistence?
        if policy.definition.persistence.applicable && phase != "initial" {
            guard let claim = savedGeneration.beforeRequestClaim,
                let requestID = claim["beforeRequestID"] as? String,
                let hash = baseline.digest
            else { throw FunctionalFailure.invalid("missing actual preserved before-request read") }
            prior = .init(
                reader: "independent-hosted-producer", observationID: baseline.identifier,
                capabilitySHA256: held.capabilitySHA256, engine: held.capability.engine,
                ui: held.capability.ui,
                beforeRequestID: requestID, sequence: baseline.sequence, readbackSHA256: hash,
                expectedSHA256: hash)
        } else {
            prior = nil
        }
        var colorHistory: [FunctionalCollectedEvidence.ColorPickerHistoryFacts] = []
        if owner == "colorPicker" {
            for start in starts {
                guard let index = start.stepIndex, stepRawSnapshots.indices.contains(index),
                    let providerBefore = stepReadbacks[index].before.bytes,
                    let providerAfter = stepReadbacks[index].after.bytes,
                    let rawBefore = try stepRawSnapshots[index].before.rawBytes(
                        name: "preferences"),
                    let rawAfter = try stepRawSnapshots[index].after.rawBytes(name: "preferences")
                else {
                    throw FunctionalFailure.invalid(
                        "missing actual Color Picker original history bytes")
                }
                func preferences(_ bytes: Data) throws -> Data {
                    let value = try FunctionalBytes.object(bytes)
                    guard let text = value["preferences"] as? String,
                        let result = Data(base64Encoded: text),
                        result.base64EncodedString() == text
                    else {
                        throw FunctionalFailure.invalid("actual original provider preference plist")
                    }
                    return result
                }
                colorHistory.append(
                    .init(
                        binding: binding, requestID: start.token,
                        providerBeforePreferences: try preferences(providerBefore),
                        providerAfterPreferences: try preferences(providerAfter),
                        rawBeforePreferences: rawBefore, rawAfterPreferences: rawAfter))
            }
        }
        let retired = try retiredBirths[owner, default: []].map {
            try JSONDecoder().decode(
                HostedFunctionalProcessIdentity.self,
                from: FunctionalBytes.canonical($0.contractObject))
        }
        let facts = FunctionalEvidenceAssembly.GenerationFacts(
            capability: held.capability,
            presentationID: held.presentationID, admission: admissionFacts,
            baseline: try JSONDecoder().decode(
                HostedFunctionalMutationJournal.Baseline.self,
                from: FunctionalBytes.canonical(baselineObject)), loadSequence: loadSequence,
            recipeStepCount: actor.stepCount,
            authoritativeReadPolicy: FunctionalProducerBuild.authoritativeReadPolicies[owner]!,
            events: events, steps: steps,
            authoritative: .init(
                observationID: authoritative.observationID, sequence: authoritative.sequence,
                bytes: authoritativeBytes),
            persistence: .init(
                name: policy.definition.persistence.name, readbackSHA256: finalPersistence.digest,
                expectedSHA256: finalPersistence.expectedBytes.map(FunctionalBytes.digest),
                beforeActivation: prior, sequence: finalPersistence.sequence),
            rawBaseline: baseline.bytes, rawSaved: finalPersistence.bytes, retired: retired,
            drain: drain,
            colorPickerHistory: colorHistory, sealedThroughSequence: finalPersistence.sequence)
        let stage = try FunctionalEvidenceAssembly.stage(facts: facts, policy: policy)
        let collector: FunctionalCollectedEvidence
        if let existing = collectors[owner] {
            collector = existing
        } else {
            collector = try FunctionalCollectedEvidence(
                sourceCommit: issuer.sourceCommit, session: issuer.session,
                owner: owner, uid: getuid(), compiledPolicy: policy)
            collectors[owner] = collector
        }
        try collector.appendStage(stage)
        let inventory = try stepInventories.map {
            value -> FunctionalEvidenceSealing.StepInventory in
            guard let index = value["index"] as? Int,
                let before = value["before"] as? [String: Any],
                let after = value["after"] as? [String: Any]
            else { throw FunctionalFailure.invalid("actual original step inventory") }
            return .init(
                index: index, beforeData: try FunctionalBytes.canonical(before),
                afterData: try FunctionalBytes.canonical(after))
        }
        let envelope = try FunctionalBytes.object(drainClaim)
        guard let payload = envelope["payload"] as? String,
            let receipt = try FunctionalBytes.object(Data(payload.utf8))["receipt"]
                as? [String: Any]
        else {
            throw FunctionalFailure.invalid("source-issued drain payload")
        }
        let observation = try FunctionalEvidenceSealing.presentation(
            stage: stage, recipe: recipe, definition: definition,
            inventories: inventory, drainReceipt: FunctionalBytes.canonical(receipt))
        let signed = try issuer.sealPresentation(
            payload: observation, capability: held.capability, presentationID: held.presentationID)
        completedStages[owner, default: []].append(stage)
        presentationClaims[owner, default: [:]][phase] = signed
        return signed
    }

    func sealOwnerProof(owner: String) throws -> FunctionalEvidenceSealing.OwnerProof {
        try requireHealthy()
        guard held == nil, reservation == nil, savedGeneration == nil,
            ownerProofs[owner] == nil, let collector = collectors[owner],
            let stages = completedStages[owner], stages.count == 3,
            stages.map({ $0.capability.phase }) == ["initial", "updated", "reinstalled"],
            let claims = removalClaims[owner], claims.count == 2,
            let preserved = preservedSaved[owner]
        else { throw FunctionalFailure.invalid("missing actual completed owner proof facts") }
        try preserved.reader.requirePreserved(since: preserved.observation)
        let current = try preserved.reader.observeSentinels()
        func payload(_ envelope: Data) throws -> [String: Any] {
            let fields = try FunctionalBytes.object(envelope)
            guard let text = fields["payload"] as? String else {
                throw FunctionalFailure.invalid("source-issued removal envelope")
            }
            let value = try FunctionalBytes.object(Data(text.utf8))
            guard value["sourceCommit"] as? String == issuer.sourceCommit,
                value["session"] as? String == issuer.session,
                value["owner"] as? String == owner
            else { throw FunctionalFailure.invalid("actual owner removal source scope") }
            return value
        }
        let first = try payload(claims[0])
        let last = try payload(claims[1])
        guard let firstReceipt = first["receipt"] as? [String: Any],
            let lastReceipt = last["receipt"] as? [String: Any],
            let firstAbsent = firstReceipt["physicallyAbsentVersions"] as? [String],
            let lastAbsent = lastReceipt["physicallyAbsentVersions"] as? [String],
            let before = last["before"] as? [String: Any],
            let after = last["after"] as? [String: Any],
            let beforeFiles = before["files"] as? [[String: Any]],
            let afterFiles = after["files"] as? [[String: Any]],
            try FunctionalBytes.boolean(firstReceipt, "leasesReleased"),
            try FunctionalBytes.boolean(lastReceipt, "leasesReleased"),
            try FunctionalBytes.boolean(lastReceipt, "sentinelBytesPreserved"),
            try FunctionalBytes.boolean(lastReceipt, "semanticDataPreserved"),
            try rawFingerprint(preserved.observation) == rawFingerprint(current)
        else {
            throw FunctionalFailure.invalid(
                "actual final physical removal or saved preservation facts")
        }
        let binding = stages[0].admission.binding
        let leases = stages.flatMap { $0.drain.capturedLeaseTokens }
        let released = stages.flatMap { $0.drain.releasedLeaseTokens }
        let evidence = try collector.finish(
            removal: .init(
                sourceCommit: binding.sourceCommit,
                session: binding.session, owner: owner, caseSHA256: binding.caseSHA256,
                capturedVersions: [stages[0].capability.version, stages[1].capability.version],
                physicallyAbsentBeforeReinstall: firstAbsent, finalPhysicallyAbsent: lastAbsent,
                capturedLeaseTokens: leases, releasedLeaseTokens: released,
                leasesReleased: try FunctionalBytes.boolean(lastReceipt, "leasesReleased")),
            sentinels: .init(
                sourceCommit: binding.sourceCommit, session: binding.session, owner: owner,
                caseSHA256: binding.caseSHA256,
                before: try FunctionalBytes.canonical(
                    beforeFiles.map { $0.filter { $0.key != "identity" } }),
                after: try FunctionalBytes.canonical(
                    afterFiles.map { $0.filter { $0.key != "identity" } })))
        let proof = try FunctionalEvidenceSealing.sealOwner(
            evidence: evidence, owner: owner,
            caseSHA256: binding.caseSHA256, publicKey: issuer.publicKey,
            sign: { try self.issuer.seal(FunctionalBytes.object($0)) })
        ownerProofs[owner] = proof
        return proof
    }

    func completedOwnerProofs() throws -> [FunctionalEvidenceSealing.OwnerProof] {
        try requireHealthy()
        guard held == nil, reservation == nil, savedGeneration == nil,
            Set(ownerProofs.keys) == HostedFunctionalActionContext.owners
        else {
            throw FunctionalFailure.invalid("incomplete actual exact owner proof set")
        }
        return try FunctionalEvidenceSealing.owners.map { owner in
            guard let proof = ownerProofs[owner] else {
                throw FunctionalFailure.invalid("missing actual owner proof")
            }
            return proof
        }
    }

    func completedRetirementSignals() throws -> Int {
        _ = try completedOwnerProofs()
        return completedStages.values.flatMap { $0 }.reduce(0) {
            $0 + $1.drain.engineStop.signalAttempts.count + $1.drain.nativeStop.signalAttempts.count
        }
    }

    private func rawFingerprint(_ observation: FunctionalOwnerSavedReader.RawObservation) throws
        -> Data
    {
        guard let files = observation.object["files"] as? [[String: Any]] else {
            throw FunctionalFailure.invalid("actual raw removal files")
        }
        return try FunctionalBytes.canonical(files.map { $0.filter { $0.key != "identity" } })
    }

    private func captureHeldLease(_ held: FunctionalHeldPresentation) throws {
        guard capturedLeases.isEmpty, releasedLeaseTokens.isEmpty else {
            throw FunctionalFailure.invalid("overlapping actual lease observations")
        }
        let directory = root.url.appendingPathComponent(
            "Edith Tests/worker-" + issuer.session + "/Extensions/.leases")
        let parent = try FunctionalPinnedPath(directory, directory: true)
        let file = try FunctionalPinnedPath(
            directory.appendingPathComponent(
                held.capability.owner + "-edith-host-2-arm64-" + held.capability.version + ".lock"),
            directory: false, privateMode: true, maximum: 0)
        let descriptor = open(file.url.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FunctionalFailure.invalid("actual held lease observation")
        }
        let result = flock(descriptor, LOCK_EX | LOCK_NB)
        let observedError = errno
        if result == 0 { _ = flock(descriptor, LOCK_UN) }
        let closed = close(descriptor)
        guard result == -1, observedError == EWOULDBLOCK, closed == 0 else {
            throw FunctionalFailure.invalid("original installed owner has no active shared lease")
        }
        try file.requireCurrent()
        try parent.requireCurrent()
        try held.requireCurrent()
        capturedLeases.append((UUID().uuidString.lowercased(), file))
    }

    private func releaseCapturedLeases() throws {
        guard !capturedLeases.isEmpty, releasedLeaseTokens.isEmpty else {
            throw FunctionalFailure.invalid("missing actual captured lease observations")
        }
        for captured in capturedLeases {
            try captured.file.requireCurrent()
            let descriptor = open(
                captured.file.url.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw FunctionalFailure.invalid("actual released lease observation")
            }
            let acquired = flock(descriptor, LOCK_EX | LOCK_NB)
            let released = acquired == 0 ? flock(descriptor, LOCK_UN) : -1
            let closed = close(descriptor)
            guard acquired == 0, released == 0, closed == 0 else {
                throw FunctionalFailure.invalid("actual original lease still retained")
            }
            try captured.file.requireCurrent()
            releasedLeaseTokens.append(captured.token)
        }
    }

    private func probePackageLeases(owner: String) throws -> Bool {
        let directory = root.url.appendingPathComponent(
            "Edith Tests/worker-" + issuer.session + "/Extensions/.leases")
        let parent = try FunctionalPinnedPath(directory, directory: true)
        for version in ["1.0.0", "1.1.0"] {
            let url = directory.appendingPathComponent(
                owner + "-edith-host-2-arm64-" + version + ".lock")
            let pinned = try FunctionalPinnedPath(
                url, directory: false, privateMode: true, maximum: 0)
            let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw FunctionalFailure.invalid("actual version lease probe")
            }
            let acquired = flock(descriptor, LOCK_EX | LOCK_NB)
            let released = acquired == 0 ? flock(descriptor, LOCK_UN) : -1
            let closed = close(descriptor)
            guard acquired == 0, released == 0, closed == 0 else {
                throw FunctionalFailure.invalid("actual version lease retained")
            }
            try pinned.requireCurrent()
        }
        try parent.requireCurrent()
        return true
    }

    func closeAndJoin() async throws {
        if closed && socket == nil { return }
        guard !closed, let socket else {
            throw FunctionalFailure.invalid("producer receiver join did not complete")
        }
        closed = true
        try await socket.closeAndJoin()
        self.socket = nil
    }

    private func readOriginalState(held: FunctionalHeldPresentation) async throws
        -> FunctionalOriginalReadObservation
    {
        guard originalRead == nil, let host,
            let bytes = FunctionalProducerBuild.authoritativeReadPolicies[held.capability.owner],
            let normalizer = FunctionalProducerBuild.authoritativeNormalizers[held.capability.owner]
        else {
            throw FunctionalFailure.invalid("missing compiled original readback selector")
        }
        let selector = try FunctionalBytes.object(bytes, maximum: 262_144)
        try FunctionalBytes.exact(selector, ["schema", "owner", "operation", "payload"])
        guard try FunctionalBytes.integer(selector, "schema") == 1,
            selector["owner"] as? String == held.capability.owner,
            let operation = selector["operation"] as? String,
            held.capability.operations.contains(operation),
            let object = selector["payload"] as? [String: Any]
        else {
            throw FunctionalFailure.invalid("source original readonly selector")
        }
        let payload = try FunctionalBytes.canonical(object)
        let token = UUID().uuidString.lowercased()
        let observation = FunctionalOriginalReadObservation(
            held: held, host: host, token: token, operation: operation, payload: payload)
        originalRead = observation
        defer { originalRead = nil }
        let result = try await bridge.forward(
            owner: held.capability.owner, operation: "read-original-state",
            fields: [
                "token": token, "readOperation": operation,
                "payload": payload.base64EncodedString(),
            ])
        try FunctionalBytes.exact(
            result,
            [
                "schema", "sourceCommit", "session", "requestID", "operation", "owner", "token",
                "payload", "payloadSHA256",
            ])
        guard result["token"] as? String == token, let text = result["payload"] as? String,
            let actual = Data(base64Encoded: text), actual.base64EncodedString() == text,
            actual.count <= 1_048_576,
            result["payloadSHA256"] as? String == FunctionalBytes.digest(actual)
        else {
            throw FunctionalFailure.invalid("actual original Host readback correlation")
        }
        try observation.complete(actual)
        try observation.normalize(normalizer)
        observationSequence += 1
        observation.sequence = observationSequence
        return observation
    }

    private func isActivationMutation(_ request: [String: Any], held: FunctionalHeldPresentation)
        throws -> Bool
    {
        guard let operation = request["operation"] as? String else {
            throw FunctionalFailure.invalid("actual original request operation")
        }
        if operation != held.capability.activationOperation { return false }
        guard let source = FunctionalProducerBuild.authoritativeReadPolicies[held.capability.owner],
            let text = request["payload"] as? String, let bytes = Data(base64Encoded: text),
            bytes.base64EncodedString() == text
        else { throw FunctionalFailure.invalid("actual source request classification bytes") }
        let selector = try FunctionalBytes.object(source)
        try FunctionalBytes.exact(selector, ["schema", "owner", "operation", "payload"])
        guard try FunctionalBytes.integer(selector, "schema") == 1,
            selector["owner"] as? String == held.capability.owner,
            let readOperation = selector["operation"] as? String,
            let payload = selector["payload"] as? [String: Any]
        else {
            throw FunctionalFailure.invalid("source-owned original readonly classification")
        }
        let expected = try FunctionalBytes.canonical(payload)
        guard let original = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw FunctionalFailure.invalid("actual original request object payload")
        }
        let actual = try FunctionalBytes.canonical(original)
        return !(operation == readOperation && actual == expected)
    }

    private func receive(_ caller: FunctionalSocketPeer, _ message: [String: Any]) async throws
        -> Data
    {
        try requireHealthy()
        guard try FunctionalBytes.integer(message, "schema") == 1,
            message["sourceCommit"] as? String == issuer.sourceCommit,
            message["session"] as? String == issuer.session,
            let requestID = message["requestID"] as? String, FunctionalBytes.uuid(requestID),
            requestIDs.count < requestLimit, requestIDs.insert(requestID).inserted,
            let operation = message["operation"] as? String,
            let owner = message["owner"] as? String,
            HostedFunctionalActionContext.owners.contains(owner)
        else { throw FunctionalFailure.invalid("source-owned original receiver event") }
        if ["authorize-original-step", "complete-original-step"].contains(operation) {
            guard let held, let journal, let actor = xctestActor, held.capability.owner == owner
            else {
                throw FunctionalFailure.invalid("unregistered source-built XCTest actor")
            }
            var result = try actor.receive(
                operation: operation, caller: caller.birth, message: message, journal: journal)
            if operation == "authorize-original-step" {
                guard beforeStepRead == nil else {
                    throw FunctionalFailure.invalid("unreleased actual original step readback")
                }
                guard let reservation else {
                    throw FunctionalFailure.invalid("unreserved actual step inventory")
                }
                beforeStepInventory = try await held.observedInventory(
                    descriptors: reservation.currentDescriptors())
                beforeStepRead = try await readOriginalState(held: held)
                if owner == "calendar" {
                    guard let savedGeneration,
                        let authorizationID = result["authorizationID"] as? String
                    else {
                        throw FunctionalFailure.invalid("missing real Calendar local authorization")
                    }
                    try savedGeneration.beforeLocalControl(authorizationID, held: held)
                }
                guard let savedGeneration else {
                    throw FunctionalFailure.invalid("missing actual step saved source")
                }
                beforeStepRaw = try savedGeneration.reader.observeSentinels()
            } else {
                guard let beforeStepRead, let index = result["stepIndex"] as? Int else {
                    throw FunctionalFailure.invalid("missing actual before-step readback")
                }
                let after = try await readOriginalState(held: held)
                guard let reservation, let beforeStepInventory else {
                    throw FunctionalFailure.invalid("missing actual before-step inventory")
                }
                let afterInventory = try await held.observedInventory(
                    descriptors: reservation.currentDescriptors())
                guard
                    try FunctionalBytes.canonical(beforeStepInventory)
                        == FunctionalBytes.canonical(afterInventory)
                else {
                    throw FunctionalFailure.invalid(
                        "actual original inventory changed across XCTest action")
                }
                stepInventories.append([
                    "index": index, "before": beforeStepInventory, "after": afterInventory,
                ])
                self.beforeStepInventory = nil
                guard let beforeStepRaw, let savedGeneration else {
                    throw FunctionalFailure.invalid("missing before-step raw source observation")
                }
                let afterRaw = try savedGeneration.reader.observeSentinels()
                stepRawSnapshots.append((index, beforeStepRaw, afterRaw))
                self.beforeStepRaw = nil
                stepReadbacks.append((index, beforeStepRead, after))
                self.beforeStepRead = nil
            }
            if owner == "calendar" {
                observationSequence += 1
                result["lastEventOrdinal"] = observationSequence
                if operation == "authorize-original-step" {
                    actor.bindLocalObservationStart(observationSequence)
                }
                result["firstEventOrdinal"] = try actor.localObservationStart()
            }
            let envelope = try issuer.seal(
                result.merging([
                    "schema": 1, "sourceCommit": issuer.sourceCommit,
                    "session": issuer.session, "requestID": requestID, "operation": operation,
                    "owner": owner,
                    "phase": held.capability.phase,
                ]) { _, new in new })
            try actor.retainEnvelope(operation: operation, bytes: envelope)
            return envelope
        }
        if FunctionalGenerationReservation.operations.contains(operation) {
            guard let reservation, reservation.owner == owner else {
                throw FunctionalFailure.invalid(
                    "original lifecycle has no source-owned reservation")
            }
            observationSequence += 1
            let result = try reservation.receive(
                operation: operation, caller: caller.birth, message: message,
                sequence: observationSequence)
            if let current = reservation.held, held == nil { try hold(current) }
            return try issuer.seal(
                result.merging([
                    "schema": 1, "sourceCommit": issuer.sourceCommit,
                    "session": issuer.session, "requestID": requestID, "operation": operation,
                    "owner": owner, "phase": reservation.phase,
                ]) { _, new in new })
        }
        guard let event = FunctionalRequestJournal.Event(rawValue: operation) else {
            throw FunctionalFailure.invalid("uncompiled original receiver operation")
        }
        guard let held, let journal, held.capability.owner == owner else {
            throw FunctionalFailure.invalid("original receiver has no admitted held generation")
        }
        let common: Set<String> = [
            "schema", "sourceCommit", "session", "requestID", "operation", "owner",
        ]
        let eventFields: Set<String>
        switch event {
        case .hostBefore: eventFields = ["ui", "engine", "receiver", "request"]
        case .engineBefore: eventFields = ["source", "receiver", "request", "endpoint"]
        case .engineAfter: eventFields = ["source", "receiver", "request", "endpoint", "result"]
        case .hostAfter: eventFields = ["ui", "engine", "receiver", "request", "result"]
        case .nativeReply:
            eventFields = ["ui", "receiver", "request", "reply", "encodedReplySHA256"]
        }
        try FunctionalBytes.exact(message, common.union(eventFields))
        if let originalRead, let request = message["request"] as? [String: Any],
            request["token"] as? String == originalRead.token
        {
            observationSequence += 1
            try originalRead.receive(
                event: event, caller: caller.birth, message: message, sequence: observationSequence)
            return try issuer.seal([
                "schema": 1, "sourceCommit": issuer.sourceCommit, "session": issuer.session,
                "requestID": requestID, "operation": operation, "owner": owner,
                "phase": held.capability.phase,
                "capabilitySHA256": held.capabilitySHA256, "presentationID": held.presentationID,
                "readToken": originalRead.token,
            ])
        }
        if event == .hostBefore, let request = message["request"] as? [String: Any],
            try isActivationMutation(request, held: held),
            let token = request["token"] as? String
        {
            guard xctestActor?.isAuthorized == true else {
                throw FunctionalFailure.invalid(
                    "original mutation before actual XCTest actor authorization")
            }
            if let savedGeneration, savedGeneration.persistence.firstRequestID == nil {
                try savedGeneration.beforeFirstRequest(token)
            }
        }
        observationSequence += 1
        try journal.receive(
            event: event, caller: caller.birth,
            fields: message.filter { eventFields.contains($0.key) }, sequence: observationSequence,
            activationID: xctestActor?.currentAuthorizationID,
            stepIndex: xctestActor?.currentStepIndex)
        try requireHealthy()
        return try issuer.seal([
            "schema": 1, "sourceCommit": issuer.sourceCommit,
            "session": issuer.session, "requestID": requestID, "operation": operation,
            "owner": owner, "phase": held.capability.phase,
            "capabilitySHA256": held.capabilitySHA256, "presentationID": held.presentationID,
            "eventOrdinal": journal.records.count - 1,
        ])
    }
}

@MainActor
final class FunctionalOriginalReadObservation {
    let token: String
    let operation: String
    let payload: Data
    let observationID = UUID().uuidString.lowercased()
    var sequence = 0
    private let held: FunctionalHeldPresentation
    private let host: FunctionalBirth
    private var started = false
    private var responseSHA256: String?
    private(set) var bytes: Data?
    private(set) var normalizedBytes: Data?
    private(set) var eventRows: [[String: Any]] = []

    init(
        held: FunctionalHeldPresentation, host: FunctionalBirth, token: String, operation: String,
        payload: Data
    ) {
        self.held = held
        self.host = host
        self.token = token
        self.operation = operation
        self.payload = payload
    }

    func receive(
        event: FunctionalRequestJournal.Event, caller: FunctionalBirth, message: [String: Any],
        sequence: Int
    ) throws {
        guard event == .engineBefore || event == .engineAfter,
            let request = message["request"] as? [String: Any],
            request["token"] as? String == token,
            request["operation"] as? String == operation,
            request["payloadSHA256"] as? String == FunctionalBytes.digest(payload),
            try FunctionalBytes.integer(request, "payloadBytes") == payload.count,
            let source = message["source"] as? [String: Any],
            let receiver = message["receiver"] as? [String: Any],
            try FunctionalBytes.canonical(source) == FunctionalBytes.canonical(host.object),
            try FunctionalBytes.canonical(receiver) == FunctionalBytes.canonical(held.engine.object)
        else {
            throw FunctionalFailure.invalid("actual original readonly engine event binding")
        }
        try host.requireCurrent()
        try held.requireObserver(caller, engineReceiver: true)
        if let text = request["payload"] as? String {
            guard text == payload.base64EncodedString() else {
                throw FunctionalFailure.invalid("changed original read request bytes")
            }
        } else {
            throw FunctionalFailure.invalid("missing original read request bytes")
        }
        if event == .engineBefore {
            guard !started, responseSHA256 == nil else {
                throw FunctionalFailure.invalid("replayed original readonly engine admission")
            }
            started = true
        } else {
            guard started, responseSHA256 == nil, let result = message["result"] as? [String: Any],
                try FunctionalBytes.boolean(result, "ok"),
                let digest = result["payloadSHA256"] as? String,
                FunctionalBytes.hex(digest, length: 64),
                try FunctionalBytes.integer(result, "payloadBytes") <= 1_048_576
            else {
                throw FunctionalFailure.invalid("original readonly engine completion")
            }
            responseSHA256 = digest
            if let text = result["payload"] as? String {
                guard let actual = Data(base64Encoded: text), actual.base64EncodedString() == text,
                    actual.count == (try FunctionalBytes.integer(result, "payloadBytes")),
                    FunctionalBytes.digest(actual) == digest
                else { throw FunctionalFailure.invalid("original readonly engine result bytes") }
                bytes = actual
            } else {
                throw FunctionalFailure.invalid("missing original readonly engine result")
            }
        }
        guard sequence > (eventRows.last?["sequence"] as? Int ?? 0), eventRows.count < 2 else {
            throw FunctionalFailure.invalid("actual independent readonly event sequencing")
        }
        eventRows.append([
            "ordinal": eventRows.count, "sequence": sequence,
            "event": event.rawValue, "token": token, "operation": operation,
            "presentationID": held.presentationID, "caller": caller.contractObject,
            "source": host.contractObject, "receiver": held.engine.contractObject,
            "payload": payload.base64EncodedString(),
            "payloadSHA256": FunctionalBytes.digest(payload),
            "response": event == .engineAfter
                ? bytes?.base64EncodedString() as Any? ?? NSNull() : NSNull(),
            "responseSHA256": event == .engineAfter ? responseSHA256 as Any? ?? NSNull() : NSNull(),
            "outcome": event == .engineAfter ? true : NSNull(),
        ])
    }

    func normalize(_ definition: Data) throws {
        guard normalizedBytes == nil, let bytes else {
            throw FunctionalFailure.invalid("missing completed actual original readback")
        }
        normalizedBytes = try FunctionalFileScopes.normalizeActualRead(
            bytes, owner: held.capability.owner, definition: definition)
    }

    func complete(_ actual: Data) throws {
        try held.requireCurrent()
        try host.requireCurrent()
        guard started, eventRows.count == 2, responseSHA256 == FunctionalBytes.digest(actual),
            bytes == nil || bytes == actual,
            (try? JSONSerialization.jsonObject(with: actual, options: .fragmentsAllowed)) != nil
        else { throw FunctionalFailure.invalid("unobserved genuine original state readback") }
        bytes = actual
    }
}

@MainActor
final class FunctionalGenerationReservation {
    enum Stage { case preparing, frozen, granted, closing, drained }
    static let notificationLimit = 128
    private var notificationCounts: [String: Int] = [:]
    static let operations: Set<String> = [
        "admit-starting-reservation", "prepared-original-peers", "admit-engine", "admit-ui",
        "owner-joined", "command-cancelled", "command-retirement-started", "native-stop-prepared",
        "engine-stop-observed", "native-stop-observed",
    ]
    let owner: String
    let phase: String
    private(set) var stage = Stage.preparing
    private(set) var held: FunctionalHeldPresentation?
    let presentationRequest: [String: Any]
    private let root: FunctionalPinnedPath
    private let issuer: FunctionalIssuer
    private let producer: FunctionalBirth
    private let host: FunctionalBirth
    private let policy: WorkerFixtureRolePolicy
    private let scopes: FunctionalFileScopes
    private let capabilityTemplate: [String: Any]
    private let packageBytes: Data
    private let generation = UUID().uuidString.lowercased()
    private var engine: FunctionalBirth?
    private var ui: FunctionalBirth?
    private var configurationBytes: Data?
    private var engineAdmitted = false
    private var uiAdmitted = false
    private(set) var isPresented = false
    private var uiCodeHash: Data?
    private var descriptors: [FunctionalPinnedPath] = []
    private var joinedTokens: [String: Set<String>] = ["engine": [], "ui": []]
    private var cancelledTokens: [String: Set<String>] = ["engine": [], "ui": []]
    private var retirementTokens: [String: Set<String>] = ["engine": [], "ui": []]
    private var stopPreparationToken: String?
    private var stoppedUIJoinedTokens: Set<String>?
    private var engineStopBytes: Data?
    private var engineStopSequence: Int?
    private var nativeStopSequence: Int?
    private var nativeStopBytes: Data?

    init(
        owner: String, phase: String, root: FunctionalPinnedPath, issuer: FunctionalIssuer,
        producer: FunctionalBirth, host: FunctionalBirth
    ) throws {
        guard HostedFunctionalActionContext.owners.contains(owner),
            let filePhase = WorkerFixtureFilePhase(rawValue: phase),
            let policy = FunctionalProducerBuild.rolePolicies.first(where: { $0.owner == owner }),
            let recipeBytes = FunctionalProducerBuild.recipes[owner],
            let caseSHA256 = FunctionalProducerBuild.caseDigests[owner],
            let activation = FunctionalProducerBuild.activationOperations[owner],
            policy.operations == FunctionalProducerBuild.operations[owner]
        else { throw FunctionalFailure.invalid("literal original generation policy") }
        try root.requireCurrent()
        try producer.requireCurrent()
        try host.requireCurrent()
        let recipe = try FunctionalBytes.object(recipeBytes)
        guard let location = recipe["location"] as? String,
            let section = recipe["section"] as? String,
            policy.presentations.contains(where: {
                $0.location == location && $0.section == section
            })
        else { throw FunctionalFailure.invalid("literal original presentation scope") }
        let version = phase == "initial" ? "1.0.0" : "1.1.0"
        let prepared = root.url.appendingPathComponent("packages-" + owner + "-" + version)
        let metadata = try FunctionalPinnedPath(
            prepared.appendingPathComponent(owner + ".json"), directory: false, maximum: 1_048_576)
        let archive = try FunctionalPinnedPath(
            prepared.appendingPathComponent(owner + ".zip"), directory: false, maximum: 536_870_912)
        let archiveBytes = try archive.read()
        let package = try FunctionalIssuer.sourcePackage(
            metadata: metadata.read(), owner: owner, version: version,
            archiveSHA256: FunctionalBytes.digest(archiveBytes), archiveBytes: archiveBytes.count)
        packageBytes = try FunctionalBytes.canonical(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(package)))
        let resolved = try policy.resolvedOwnedPaths(
            root: root.url.path, session: issuer.session, phase: filePhase)
        scopes = try FunctionalFileScopes(resolved: resolved, root: root)
        let template: [String: Any] = [
            "schema": 1, "sourceCommit": issuer.sourceCommit, "session": issuer.session,
            "owner": owner, "uid": getuid(), "fixtureRoot": root.url.path,
            "hostIdentifier": FunctionalProducerBuild.hostIdentifier,
            "home": root.url.path + "/" + owner + "-home",
            "dataDirectory": root.url.path + "/Edith Tests/worker-" + issuer.session + "/Data/"
                + owner,
            "hostABI": "edith-host-2", "caseSHA256": caseSHA256,
            "activationOperation": activation as Any? ?? NSNull(),
            "phase": phase, "pairScope": "synthetic-development", "previousVersion": "1.0.0",
            "currentVersion": "1.1.0",
            "version": version, "packageSHA256": package.sha256, "operations": policy.operations,
            "ownedPaths": resolved.map {
                ["name": $0.scope.name, "path": $0.path, "kind": $0.scope.kind.rawValue]
            },
        ]
        let identifier = try FunctionalHeldPresentation.derivePresentationID(
            FunctionalBytes.canonical(template))
        presentationRequest = [
            "phase": phase, "location": location, "section": section, "presentationID": identifier,
        ]
        capabilityTemplate = template
        self.owner = owner
        self.phase = phase
        self.root = root
        self.issuer = issuer
        self.producer = producer
        self.host = host
        self.policy = policy
    }

    func receive(operation: String, caller: FunctionalBirth, message: [String: Any], sequence: Int)
        throws -> [String: Any]
    {
        try root.requireCurrent()
        try producer.requireCurrent()
        try host.requireCurrent()
        let common: Set<String> = [
            "schema", "sourceCommit", "session", "requestID", "operation", "owner",
        ]
        switch operation {
        case "admit-starting-reservation":
            try FunctionalBytes.exact(
                message, common.union(["configuration", "engine", "request"]))
            guard stage == .preparing, engine == nil, caller == host,
                let configuration = message["configuration"] as? [String: Any],
                let observed = message["engine"] as? [String: Any],
                let request = message["request"] as? [String: Any]
            else { throw FunctionalFailure.invalid("actual original starting reservation order") }
            try requireConfiguration(configuration)
            try requireRequest(request)
            let birth = try currentBirth(observed)
            guard birth != host, birth != producer, birth.executable == host.executable else {
                throw FunctionalFailure.invalid("original starting engine executable")
            }
            try FunctionalHeldPresentation.signer(
                identifier: FunctionalProducerBuild.hostIdentifier
            )
            .verify(root.url.appendingPathComponent("Fixture.app"), birth: birth)
            engine = birth
            configurationBytes = try FunctionalBytes.canonical(configuration)
        case "admit-ui":
            guard let configuration = message["configuration"] as? [String: Any], let engine else {
                throw FunctionalFailure.invalid("native UI before engine reservation")
            }
            try requireConfiguration(configuration)
            guard try FunctionalBytes.canonical(configuration) == configurationBytes else {
                throw FunctionalFailure.invalid("native UI changed original reservation")
            }
            let worker = workerPath
            guard caller.executable == worker + "/Contents/MacOS/Edith", caller != producer,
                caller != host, caller != engine
            else { throw FunctionalFailure.invalid("actual original UI peer birth") }
            try FunctionalHeldPresentation.signer(
                identifier: FunctionalProducerBuild.hostIdentifier + ".extension." + owner
                    + ".worker"
            )
            .verify(URL(fileURLWithPath: worker), birth: caller)
            if let presentation = message["presentation"] as? [String: Any] {
                try FunctionalBytes.exact(message, common.union(["configuration", "presentation"]))
                guard stage == .frozen || stage == .granted, ui == caller, !uiAdmitted,
                    let request = presentation["request"] as? [String: Any],
                    presentation["session"] as? String == configuration["session"] as? String
                else { throw FunctionalFailure.invalid("original UI construction admission order") }
                try requireRequest(request)
                try held?.requireCurrent()
                uiAdmitted = true
                if engineAdmitted { stage = .granted }
                return ["contextMarker": marker(engine: false)]
            }
            try FunctionalBytes.exact(message, common.union(["configuration"]))
            guard stage == .preparing, ui == nil else {
                throw FunctionalFailure.invalid("native UI configuration replay")
            }
            ui = caller
        case "prepared-original-peers":
            try FunctionalBytes.exact(
                message, common.union(["phase", "configuration", "request", "engine", "ui"]))
            guard stage == .preparing, caller == host, let engine, let ui,
                message["phase"] as? String == phase,
                let configuration = message["configuration"] as? [String: Any],
                let request = message["request"] as? [String: Any],
                let reportedEngine = message["engine"] as? [String: Any],
                let reportedUI = message["ui"] as? [String: Any],
                try currentBirth(reportedEngine) == engine, try currentBirth(reportedUI) == ui,
                try FunctionalBytes.canonical(configuration) == configurationBytes
            else { throw FunctionalFailure.invalid("original prepared peer reservation") }
            try requireConfiguration(configuration)
            try requireRequest(request)
            try scopes.requireCurrent()
            let capabilityBytes = try FunctionalBytes.canonical(
                capabilityTemplate.merging([
                    "engine": engine.contractObject,
                    "ui": ui.contractObject,
                ]) { _, new in new })
            guard let identifier = presentationRequest["presentationID"] as? String,
                let location = presentationRequest["location"] as? String,
                let section = presentationRequest["section"] as? String
            else { throw FunctionalFailure.invalid("producer presentation identity") }
            let next = try FunctionalHeldPresentation(
                capabilityBytes: capabilityBytes, presentationID: identifier,
                location: location, section: section, hostPID: host.pid, expectedPhase: phase,
                issuer: issuer)
            held = next
            uiCodeHash = try FunctionalHeldPresentation.signer(
                identifier: FunctionalProducerBuild.hostIdentifier + ".extension." + owner
                    + ".worker"
            )
            .codeHash(URL(fileURLWithPath: workerPath))
            let descriptor = try next.descriptor(
                location: location, section: section, issuer: issuer)
            try writeDescriptor(descriptor, name: "functional-ui-" + owner + ".json")
            let inputs = try policy.inputs.map { input -> [String: Any] in
                guard
                    let path = next.capability.ownedPaths.first(where: {
                        $0.name == input.name && $0.kind == "file"
                    }),
                    path.path.hasPrefix(root.url.path + "/inputs/" + owner + "/")
                else {
                    throw FunctionalFailure.invalid("compiled engine input path binding")
                }
                let file = try FunctionalPinnedPath(
                    URL(fileURLWithPath: path.path), directory: false, maximum: input.maximumBytes)
                let bytes = try file.read()
                guard !bytes.isEmpty else {
                    throw FunctionalFailure.invalid("empty compiled engine input")
                }
                return [
                    "name": input.name, "path": path.path, "sha256": FunctionalBytes.digest(bytes),
                    "maximumBytes": input.maximumBytes,
                ]
            }
            let outputs = try policy.outputs.map { name -> [String: Any] in
                guard
                    let path = next.capability.ownedPaths.first(where: {
                        $0.name == name && $0.kind == "file"
                    }),
                    path.path.hasPrefix(root.url.path + "/outputs/" + owner + "/")
                else {
                    throw FunctionalFailure.invalid("compiled engine output path binding")
                }
                return [
                    "name": name, "path": path.path,
                    "parent": URL(fileURLWithPath: path.path).deletingLastPathComponent().path,
                ]
            }
            let engineDescriptor = try issuer.seal([
                "schema": 1, "sourceCommit": issuer.sourceCommit, "session": issuer.session,
                "owner": owner, "phase": phase, "requestGeneration": generation,
                "capabilitySHA256": next.capabilitySHA256,
                "root": root.url.path, "hostIdentifier": FunctionalProducerBuild.hostIdentifier,
                "home": next.capability.home, "dataDirectory": next.capability.dataDirectory,
                "workerPath": workerPath,
                "rolePath": workerPath + "/Contents/Resources/Payload/" + owner + "/"
                    + policy.primaryRole.rawValue + ".bundle",
                "role": policy.primaryRole.rawValue, "version": next.capability.version,
                "hostABI": "edith-host-2",
                "packageSHA256": next.capability.packageSHA256, "producer": producer.object,
                "engine": engine.object,
                "operations": policy.operations, "inputs": inputs, "outputs": outputs,
            ])
            let verified = try WorkerFixtureEngineContract.verify(
                engineDescriptor, issuerKey: issuer.publicKey)
            try policy.validateEngine(verified)
            try writeDescriptor(engineDescriptor, name: "functional-engine-" + owner + ".json")
            try scopes.requireCurrent()
            stage = .frozen
        case "admit-engine":
            try FunctionalBytes.exact(message, common.union(["configuration"]))
            guard stage == .frozen || stage == .granted, caller == engine, !engineAdmitted,
                let configuration = message["configuration"] as? [String: Any]
            else { throw FunctionalFailure.invalid("original engine construction admission order") }
            try requireWorker(configuration)
            try held?.requireCurrent()
            engineAdmitted = true
            if uiAdmitted { stage = .granted }
            return ["contextMarker": marker(engine: true)]
        case "command-cancelled", "command-retirement-started":
            try FunctionalBytes.exact(
                message,
                common.union(
                    operation == "command-cancelled" ? ["token", "side"] : ["tokens", "side"]))
            guard stage == .frozen || stage == .granted || stage == .closing,
                let side = message["side"] as? String, ["engine", "ui"].contains(side),
                caller == (side == "engine" ? engine : ui)
            else {
                throw FunctionalFailure.invalid("actual original cancellation source")
            }
            let key = side + ":" + operation
            guard notificationCounts[key, default: 0] < Self.notificationLimit else {
                throw FunctionalFailure.invalid("bounded source-owned cancellation observations")
            }
            notificationCounts[key, default: 0] += 1
            let tokens: [String]
            if operation == "command-cancelled" {
                guard let token = message["token"] as? String else {
                    throw FunctionalFailure.invalid("actual cancellation token")
                }
                tokens = [token]
            } else {
                guard let snapshot = message["tokens"] as? [String], snapshot.count <= 128 else {
                    throw FunctionalFailure.invalid("actual finite retirement snapshot")
                }
                tokens = snapshot
            }
            guard Set(tokens).count == tokens.count, tokens.allSatisfy(FunctionalBytes.uuid),
                Set(tokens).isDisjoint(with: joinedTokens[side, default: []])
            else {
                throw FunctionalFailure.invalid("foreign or already joined cancellation token")
            }
            if operation == "command-cancelled" {
                guard cancelledTokens[side, default: []].insert(tokens[0]).inserted else {
                    throw FunctionalFailure.invalid("replayed cancellation notification")
                }
            } else {
                retirementTokens[side, default: []].formUnion(tokens)
            }
        case "owner-joined":
            try FunctionalBytes.exact(message, common.union(["token", "side"]))
            guard stage == .frozen || stage == .granted || stage == .closing,
                let side = message["side"] as? String, ["engine", "ui"].contains(side),
                caller == (side == "engine" ? engine : ui), let token = message["token"] as? String,
                FunctionalBytes.uuid(token), joinedTokens[side, default: []].insert(token).inserted
            else { throw FunctionalFailure.invalid("actual original command owner retirement") }
            let key = side + ":" + operation
            guard notificationCounts[key, default: 0] < Self.notificationLimit else {
                throw FunctionalFailure.invalid("bounded source-owned command joins")
            }
            notificationCounts[key, default: 0] += 1
        case "native-stop-prepared":
            try FunctionalBytes.exact(
                message,
                common.union(["token", "configuration", "roles", "presentations", "joinedCommands"])
            )
            guard stage == .frozen || stage == .granted, caller == ui, stopPreparationToken == nil,
                let token = message["token"] as? String, FunctionalBytes.uuid(token),
                let configuration = message["configuration"] as? [String: Any],
                let roles = message["roles"] as? [String],
                roles == (uiAdmitted ? [policy.primaryRole.rawValue] : []),
                let joinedCommands = message["joinedCommands"] as? [String],
                Set(joinedCommands).count == joinedCommands.count,
                joinedCommands.allSatisfy({ FunctionalBytes.uuid($0) }),
                Set(joinedCommands) == joinedTokens["ui", default: []],
                let presentations = message["presentations"] as? [String],
                presentations.isEmpty
                    || presentations == [presentationRequest["presentationID"] as? String ?? ""]
            else { throw FunctionalFailure.invalid("actual native original stop preparation") }
            try requireConfiguration(configuration)
            stopPreparationToken = token
            stoppedUIJoinedTokens = Set(joinedCommands)
            stage = .closing
        case "engine-stop-observed":
            try FunctionalBytes.exact(message, common.union(["receipt"]))
            guard caller == host, engineStopBytes == nil,
                let receipt = message["receipt"] as? [String: Any],
                let configuration = receipt["configuration"] as? [String: Any],
                let signals = receipt["signalAttempts"] as? [Any], signals.isEmpty,
                try FunctionalBytes.integer(receipt, "terminationStatus") == 0,
                try FunctionalBytes.integer(receipt, "terminationReason") == 1,
                let request = receipt["stopRequest"] as? [String: Any],
                let reply = receipt["stopResponse"] as? [String: Any]
            else { throw FunctionalFailure.invalid("actual natural engine stop receipt") }
            try requireWorker(configuration)
            try requireStop(request, reply: reply)
            guard let preparation = receipt["preparationRequest"] as? [String: Any],
                let prepared = receipt["preparationResponse"] as? [String: Any],
                ["prepareDisable", "prepareApplicationQuit"].contains(
                    preparation["operation"] as? String ?? ""),
                let token = preparation["token"] as? String, UUID(uuidString: token) != nil,
                prepared["token"] as? String == token, try FunctionalBytes.boolean(prepared, "ok"),
                let captured = receipt["worker"] as? [String: Any],
                let observed = receipt["observedBirths"] as? [[String: Any]]
            else {
                throw FunctionalFailure.invalid(
                    "actual original engine preparation and captured birth")
            }
            guard let engine else { throw FunctionalFailure.invalid("unobserved original engine") }
            try requireCapturedProcess(captured, expected: engine)
            try requireObservedBirths(observed)
            try engine.requireAbsent()
            engineStopBytes = try FunctionalBytes.canonical(receipt)
            engineStopSequence = sequence
            stage = .closing
        case "native-stop-observed":
            try FunctionalBytes.exact(
                message,
                common.union([
                    "configuration", "joinedTasks", "stopRequest", "stopReply", "ui", "engine",
                    "observedBirths", "signalAttempts", "invalidations",
                ]))
            guard caller == host, nativeStopBytes == nil,
                let configuration = message["configuration"] as? [String: Any],
                let signals = message["signalAttempts"] as? [Any], signals.isEmpty,
                let joined = message["joinedTasks"] as? [String], Set(joined).count == joined.count,
                Set(joined).isSubset(of: ["launch", "configure", "bootstrap", "engine-receivers"]),
                !isPresented || joined == ["engine-receivers"],
                let request = message["stopRequest"] as? [String: Any],
                let reply = message["stopReply"] as? [String: Any],
                let invalidations = message["invalidations"] as? [[String: Any]],
                invalidations.allSatisfy({
                    ($0["peerWasRunning"] is NSNull) || ($0["peerWasRunning"] as? Bool == false)
                })
            else { throw FunctionalFailure.invalid("actual natural native stop receipt") }
            try requireConfiguration(configuration)
            try requireStop(request, reply: reply)
            guard let token = request["token"] as? String,
                token.lowercased() == stopPreparationToken,
                let ui, let engine, let capturedUI = message["ui"] as? [String: Any],
                let capturedEngine = message["engine"] as? [String: Any],
                let observed = message["observedBirths"] as? [[String: Any]]
            else {
                throw FunctionalFailure.invalid("source native stop preparation and captured peers")
            }
            try requireCapturedKernel(capturedEngine, expected: engine)
            try requireCapturedKernel(capturedUI, expected: ui, codeHash: uiCodeHash)
            try requireObservedBirths(observed)
            for invalidation in invalidations {
                try FunctionalBytes.exact(invalidation, ["site", "peer", "peerWasRunning"])
                guard let site = invalidation["site"] as? String,
                    ["retired-process-release"].contains(site)
                else {
                    throw FunctionalFailure.invalid("unexpected original native invalidation site")
                }
                if let peer = invalidation["peer"] as? [String: Any] {
                    try requireCapturedKernel(peer, expected: ui, codeHash: uiCodeHash)
                }
            }
            try ui.requireAbsent()
            nativeStopBytes = try FunctionalBytes.canonical(message)
            nativeStopSequence = sequence
            stage = .closing
        default: throw FunctionalFailure.invalid("uncompiled original lifecycle operation")
        }
        return ["requestGeneration": generation]
    }

    func presentationReturned(_ response: [String: Any]) throws {
        guard stage == .granted, !isPresented, let ui,
            let reported = response["ui"] as? [String: Any],
            try currentBirth(reported.filter { $0.key != "codeHash" }) == ui,
            reported["codeHash"] as? String == uiCodeHash?.base64EncodedString()
        else { throw FunctionalFailure.invalid("actual returned original native presentation") }
        try held?.requireCurrent()
        isPresented = true
    }

    func requireDrained(journal: FunctionalRequestJournal) throws {
        try journal.requireRetirementObligations(
            cancelled: cancelledTokens["engine", default: []],
            requested: retirementTokens["engine", default: []],
            joined: joinedTokens["engine", default: []])
        guard
            cancelledTokens["ui", default: []].union(retirementTokens["ui", default: []]).isSubset(
                of: joinedTokens["ui", default: []])
        else {
            throw FunctionalFailure.invalid("unjoined actual original UI retirement obligations")
        }
        if stage == .drained {
            if owner == "calendar" {
                try journal.requireLocalControlRetired(
                    joinedEngineTokens: joinedTokens["engine", default: []])
            } else {
                try journal.requireRetired(joinedEngineTokens: joinedTokens["engine", default: []])
            }
            try engine?.requireAbsent()
            try ui?.requireAbsent()
            try scopes.requireCurrent()
            return
        }
        guard stage == .closing, engineStopBytes != nil, nativeStopBytes != nil,
            stopPreparationToken != nil,
            stoppedUIJoinedTokens == joinedTokens["ui", default: []],
            let held, let engine, let ui
        else { throw FunctionalFailure.invalid("incomplete original lifecycle retirement") }
        if owner == "calendar" {
            try journal.requireLocalControlRetired(
                joinedEngineTokens: joinedTokens["engine", default: []])
        } else {
            try journal.requireRetired(joinedEngineTokens: joinedTokens["engine", default: []])
        }
        try engine.requireAbsent()
        try ui.requireAbsent()
        try held.requireRetired()
        try scopes.requireCurrent()
        for descriptor in descriptors {
            try descriptor.requireCurrent()
            guard unlink(descriptor.url.path) == 0 else {
                throw FunctionalFailure.invalid("retired source descriptor removal")
            }
        }
        descriptors.removeAll()
        stage = .drained
    }

    func currentDescriptors() throws -> [FunctionalPinnedPath] {
        guard stage == .granted, descriptors.count == 2 else {
            throw FunctionalFailure.invalid("missing held source descriptors")
        }
        for descriptor in descriptors { try descriptor.requireCurrent() }
        return descriptors
    }

    func collectedDrain(leasesReleased: Bool) throws -> [String: Any] {
        guard stage == .drained, let engine, let ui, let engineStopBytes, let nativeStopBytes else {
            throw FunctionalFailure.invalid("uncollected actual native stop")
        }
        try engine.requireAbsent()
        try ui.requireAbsent()
        let engineStop = try FunctionalBytes.object(engineStopBytes)
        let nativeStop = try FunctionalBytes.object(nativeStopBytes)
        guard let engineSignals = engineStop["signalAttempts"] as? [Any],
            let nativeSignals = nativeStop["signalAttempts"] as? [Any],
            let joinedTasks = nativeStop["joinedTasks"] as? [String],
            let stopReply = nativeStop["stopReply"] as? [String: Any],
            let engineReply = engineStop["stopResponse"] as? [String: Any]
        else { throw FunctionalFailure.invalid("actual native collected receipts") }
        let nativeStopped = try FunctionalBytes.boolean(stopReply, "ok")
        let engineStopped = try FunctionalBytes.boolean(engineReply, "ok")
        let joined =
            joinedTasks == ["engine-receivers"]
            && stoppedUIJoinedTokens == joinedTokens["ui", default: []]
            && nativeStopped && engineStopped
        return [
            "births": [engine.contractObject, ui.contractObject], "allTasksJoined": joined,
            "birthsAbsent": stage == .drained, "leasesReleased": leasesReleased,
            "signalsSent": engineSignals.count + nativeSignals.count,
        ]
    }

    func evidenceDrain(
        binding: FunctionalCollectedEvidence.Binding,
        capturedLeaseTokens: [String], releasedLeaseTokens: [String]
    ) throws -> FunctionalCollectedEvidence.DrainFacts {
        guard stage == .drained, let engine, let ui, let engineStopBytes, let nativeStopBytes,
            let engineStopSequence, let nativeStopSequence, let stopPreparationToken,
            binding.owner == owner, binding.phase == phase,
            binding.sourceCommit == issuer.sourceCommit,
            binding.session == issuer.session
        else { throw FunctionalFailure.invalid("actual drain fact binding") }
        try engine.requireAbsent()
        try ui.requireAbsent()
        let engineObject = try FunctionalBytes.object(engineStopBytes)
        let nativeObject = try FunctionalBytes.object(nativeStopBytes)
        func identity(_ birth: FunctionalBirth) throws -> HostedFunctionalProcessIdentity {
            try JSONDecoder().decode(
                HostedFunctionalProcessIdentity.self,
                from: FunctionalBytes.canonical(birth.contractObject))
        }
        func acknowledgement(_ object: [String: Any], request: String, reply: String) throws
            -> FunctionalCollectedEvidence.StopAcknowledgement
        {
            guard let requested = object[request] as? [String: Any],
                let responded = object[reply] as? [String: Any],
                let requestID = requested["token"] as? String,
                let responseToken = responded["token"] as? String,
                let operation = requested["operation"] as? String
            else { throw FunctionalFailure.invalid("actual stop acknowledgement facts") }
            return .init(
                requestID: requestID, responseToken: responseToken, operation: operation,
                outcome: try FunctionalBytes.boolean(responded, "ok"))
        }
        func births(_ object: [String: Any]) throws -> [FunctionalCollectedEvidence.CapturedBirth] {
            guard let values = object["observedBirths"] as? [[String: Any]] else {
                throw FunctionalFailure.invalid("actual observed stop births")
            }
            return try values.map { value in
                guard let pid = Int32(exactly: try FunctionalBytes.integer(value, "pid")),
                    let seconds = Int64(
                        exactly: try FunctionalBytes.integer(value, "birthSeconds")),
                    let micros = Int32(
                        exactly: try FunctionalBytes.integer(value, "birthMicroseconds"))
                else {
                    throw FunctionalFailure.invalid("actual captured stop birth integers")
                }
                return .init(pid: pid, birthSeconds: seconds, birthMicroseconds: micros)
            }
        }
        let engineBirths = try births(engineObject)
        let nativeBirths = try births(nativeObject)
        guard let engineSignals = engineObject["signalAttempts"] as? [Int],
            let nativeSignals = nativeObject["signalAttempts"] as? [Int],
            let tasks = nativeObject["joinedTasks"] as? [String],
            let rawInvalidations = nativeObject["invalidations"] as? [[String: Any]],
            let status = Int(
                exactly: try FunctionalBytes.integer(engineObject, "terminationStatus")),
            let reason = Int(
                exactly: try FunctionalBytes.integer(engineObject, "terminationReason"))
        else {
            throw FunctionalFailure.invalid("actual native stop receipt fields")
        }
        let invalidations = try rawInvalidations.map {
            value -> FunctionalCollectedEvidence.Invalidation in
            guard let site = value["site"] as? String else {
                throw FunctionalFailure.invalid("actual invalidation site")
            }
            let peer: HostedFunctionalProcessIdentity?
            if value["peer"] is NSNull { peer = nil } else { peer = try identity(ui) }
            let running =
                value["peerWasRunning"] is NSNull
                ? nil : try FunctionalBytes.boolean(value, "peerWasRunning")
            return .init(site: site, peer: peer, peerWasRunning: running)
        }
        let observedEngine = try identity(engine)
        let observedUI = try identity(ui)
        return .init(
            binding: binding, stopPreparationToken: stopPreparationToken,
            engineStop: .init(
                stop: try acknowledgement(
                    engineObject, request: "stopRequest", reply: "stopResponse"),
                preparation: try acknowledgement(
                    engineObject, request: "preparationRequest", reply: "preparationResponse"),
                worker: observedEngine, observedBirths: engineBirths, absentBirths: engineBirths,
                terminationStatus: status, terminationReason: reason, signalAttempts: engineSignals,
                sequence: engineStopSequence),
            nativeStop: .init(
                stop: try acknowledgement(nativeObject, request: "stopRequest", reply: "stopReply"),
                ui: observedUI, engine: observedEngine, observedBirths: nativeBirths,
                absentBirths: nativeBirths,
                signalAttempts: nativeSignals, joinedTasks: tasks, invalidations: invalidations,
                sequence: nativeStopSequence),
            captured: [observedEngine, observedUI], absent: [observedEngine, observedUI],
            cancelledRequestTokens: cancelledTokens["engine", default: []].sorted(),
            retirementRequestedTokens: retirementTokens["engine", default: []].sorted(),
            joinedRequestTokens: joinedTokens["engine", default: []].sorted(),
            capturedLeaseTokens: capturedLeaseTokens, releasedLeaseTokens: releasedLeaseTokens,
            cleanupStarted: !engineSignals.isEmpty || !nativeSignals.isEmpty)
    }

    private var workerPath: String {
        root.url.path + "/Edith Tests/worker-" + issuer.session + "/Extensions/" + owner
            + "/edith-host-2/arm64/"
            + (phase == "initial" ? "1.0.0" : "1.1.0") + "/" + owner
            + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex"
    }

    private func requireWorker(_ value: [String: Any]) throws {
        guard value["identifier"] as? String == FunctionalProducerBuild.hostIdentifier,
            value["extensionID"] as? String == owner,
            value["version"] as? String == (phase == "initial" ? "1.0.0" : "1.1.0"),
            try FunctionalBytes.boolean(value, "recoveryOnly") == false,
            let text = value["supportDirectory"] as? String, let url = URL(string: text),
            url.isFileURL,
            url.standardizedFileURL.path == root.url.path
        else { throw FunctionalFailure.invalid("actual original worker configuration scope") }
    }

    private func requireConfiguration(_ value: [String: Any]) throws {
        try FunctionalBytes.exact(value, ["session", "worker", "package", "uiOnly"])
        guard let session = value["session"] as? String, UUID(uuidString: session) != nil,
            try FunctionalBytes.boolean(value, "uiOnly") == false,
            let worker = value["worker"] as? [String: Any],
            let package = value["package"] as? [String: Any],
            try FunctionalBytes.canonical(package) == packageBytes
        else { throw FunctionalFailure.invalid("same original package reservation") }
        try requireWorker(worker)
    }

    private func requireRequest(_ value: [String: Any]) throws {
        guard
            Set(value.keys).isSubset(of: [
                "extensionID", "location", "section", "presentationID", "surface", "machinesWindow",
                "herdrWindow",
            ]),
            value["extensionID"] as? String == owner,
            value["location"] as? String == presentationRequest["location"] as? String,
            value["section"] as? String == presentationRequest["section"] as? String,
            (value["presentationID"] as? String)?.lowercased() == presentationRequest[
                "presentationID"] as? String
        else { throw FunctionalFailure.invalid("source-owned original presentation request") }
    }

    private func currentBirth(_ value: [String: Any]) throws -> FunctionalBirth {
        let birth = try JSONDecoder().decode(
            FunctionalBirth.self, from: FunctionalBytes.canonical(value))
        try birth.requireCurrent()
        return birth
    }

    private func marker(engine: Bool) -> [String: String] {
        var fields = [
            "sourceCommit": issuer.sourceCommit, "session": issuer.session, "phase": phase,
            "descriptorPath": root.url.path + (engine ? "/functional-engine-" : "/functional-ui-")
                + owner + ".json",
            "capabilitySHA256": held?.capabilitySHA256 ?? "",
        ]
        if engine { fields["requestGeneration"] = generation }
        return fields
    }

    private func writeDescriptor(_ bytes: Data, name: String) throws {
        let path = root.url.appendingPathComponent(name)
        try root.requireCurrent()
        let descriptor = open(
            path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw FunctionalFailure.invalid("exclusive original descriptor publication")
        }
        defer { close(descriptor) }
        let count = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count, fsync(descriptor) == 0 else {
            throw FunctionalFailure.invalid("original descriptor write")
        }
        descriptors.append(
            try FunctionalPinnedPath(path, directory: false, privateMode: true, maximum: 131_072))
        try root.requireCurrent()
    }

    private func requireCapturedProcess(_ value: [String: Any], expected: FunctionalBirth) throws {
        try FunctionalBytes.exact(value, ["pid", "generation"])
        guard try FunctionalBytes.integer(value, "pid") == expected.pid,
            value["generation"] as? String == String(expected.birthSeconds) + "."
                + String(expected.birthMicroseconds)
        else { throw FunctionalFailure.invalid("captured original process birth") }
    }

    private func requireCapturedKernel(
        _ value: [String: Any], expected: FunctionalBirth, codeHash: Data? = nil
    ) throws {
        try FunctionalBytes.exact(
            value,
            codeHash == nil
                ? ["pid", "generation", "executable"]
                : ["pid", "generation", "executable", "codeHash"])
        guard try FunctionalBytes.integer(value, "pid") == expected.pid,
            value["generation"] as? String == String(expected.birthSeconds) + ":"
                + String(expected.birthMicroseconds),
            value["executable"] as? String == expected.executable,
            codeHash == nil || value["codeHash"] as? String == codeHash?.base64EncodedString()
        else { throw FunctionalFailure.invalid("captured original peer identity") }
    }

    private func requireObservedBirths(_ values: [[String: Any]]) throws {
        guard values.count <= 256 else {
            throw FunctionalFailure.invalid("bounded original descendant births")
        }
        var captured = Set<String>()
        for value in values {
            try FunctionalBytes.exact(value, ["pid", "generation"])
            guard let pid = Int32(exactly: try FunctionalBytes.integer(value, "pid")), pid > 1,
                let generation = value["generation"] as? String,
                captured.insert(String(pid) + ":" + generation).inserted
            else {
                throw FunctionalFailure.invalid("distinct captured original descendant")
            }
            let parts = generation.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, let seconds = UInt64(parts[0]),
                let microseconds = UInt32(parts[1]),
                seconds > 0, microseconds < 1_000_000,
                generation == String(seconds) + "." + String(microseconds)
            else { throw FunctionalFailure.invalid("original descendant kernel generation") }
            var state = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &state, size)
            guard
                result == 0 && errno == ESRCH
                    || result == size
                        && (state.pbi_start_tvsec != seconds
                            || state.pbi_start_tvusec != microseconds)
            else { throw FunctionalFailure.invalid("captured original descendant still present") }
        }
    }

    private func requireStop(_ request: [String: Any], reply: [String: Any]) throws {
        guard let token = request["token"] as? String, UUID(uuidString: token) != nil,
            reply["token"] as? String == token, request["operation"] as? String == "stop",
            try FunctionalBytes.boolean(reply, "ok") == true
        else { throw FunctionalFailure.invalid("actual original stop acknowledgment") }
    }
}

@MainActor
final class FunctionalXCTestActor {
    let recipeSHA256: String
    let stepCount: Int
    let sourceSHA256: String
    private let held: FunctionalHeldPresentation
    private var nextIndex = 0
    private let runner: URL
    private let runnerSigner: FunctionalSigner
    private let bundleSigner: FunctionalSigner
    private let bundle: URL
    private let source: FunctionalPinnedPath
    private let files: [(FunctionalPinnedPath, String)]
    private let runnerExecutableSHA256: String
    let invocationPath: String
    private let invocation: FunctionalPinnedPath
    private var birth: FunctionalBirth?
    private var authorizationID: String?
    private var firstEventOrdinal: Int?
    private var authorizationEnvelope: Data?
    private var completionEnvelope: Data?
    private var issuedObservations: [[String: Any]] = []
    private var localBefore: HostedFunctionalCalendarControlSnapshot?
    private var localStartSequence: Int?
    private var localObservations:
        [(
            index: Int, before: HostedFunctionalCalendarControlSnapshot,
            after: HostedFunctionalCalendarControlSnapshot
        )] = []
    private(set) var completed = false
    var isAuthorized: Bool { authorizationID != nil && !completed }

    init(
        held: FunctionalHeldPresentation, artifact: [String: Any], root: FunctionalPinnedPath,
        issuer: FunctionalIssuer
    ) throws {
        try FunctionalBytes.exact(
            artifact,
            [
                "runnerPath", "testBundlePath", "sourcePath", "sourceSHA256",
                "runnerIdentifier", "runnerRequirement", "runnerExecutableSHA256",
                "testBundleIdentifier",
                "testBundleRequirement", "testBundleExecutableSHA256",
            ])
        guard let recipe = FunctionalProducerBuild.recipes[held.capability.owner],
            let sourceSteps = try FunctionalBytes.object(recipe)["steps"] as? [[String: Any]],
            !sourceSteps.isEmpty, sourceSteps.count <= 16
        else { throw FunctionalFailure.invalid("compiled original XCTest steps") }
        let steps = try sourceSteps.indices.map {
            try held.originalStep(index: $0, requireNext: false)
        }
        let directory = root.url.appendingPathComponent("XCTest")
        _ = try FunctionalPinnedPath(directory, directory: true, privateMode: true)
        guard let runnerPath = artifact["runnerPath"] as? String,
            runnerPath == directory.path
                + "/DerivedData/Build/Products/Release/HostedFunctionalInstalledUITests-Runner.app",
            let bundlePath = artifact["testBundlePath"] as? String,
            bundlePath == runnerPath + "/Contents/PlugIns/HostedFunctionalInstalledUITests.xctest",
            artifact["sourcePath"] as? String == directory.path
                + "/HostedFunctionalInstalledUITests.swift",
            let sourceSHA256 = artifact["sourceSHA256"] as? String,
            FunctionalBytes.hex(sourceSHA256, length: 64),
            let runnerExecutableSHA256 = artifact["runnerExecutableSHA256"] as? String,
            FunctionalBytes.hex(runnerExecutableSHA256, length: 64),
            let bundleExecutableSHA256 = artifact["testBundleExecutableSHA256"] as? String,
            FunctionalBytes.hex(bundleExecutableSHA256, length: 64)
        else { throw FunctionalFailure.invalid("source-owned XCTest artifact paths") }
        let bundleIdentifier = "com.pulkit.edith.tests.installed-" + String(sourceSHA256.prefix(24))
        let runnerIdentifier = bundleIdentifier + ".xctrunner"
        guard artifact["runnerIdentifier"] as? String == runnerIdentifier,
            artifact["testBundleIdentifier"] as? String == bundleIdentifier,
            artifact["runnerRequirement"] as? String == "identifier \"" + runnerIdentifier + "\"",
            artifact["testBundleRequirement"] as? String == "identifier \"" + bundleIdentifier
                + "\""
        else { throw FunctionalFailure.invalid("source-owned XCTest signed identifiers") }
        let runner = URL(fileURLWithPath: runnerPath)
        let bundle = URL(fileURLWithPath: bundlePath)
        let runnerSigner = FunctionalHeldPresentation.signer(identifier: runnerIdentifier)
        let bundleSigner = FunctionalHeldPresentation.signer(identifier: bundleIdentifier)
        try runnerSigner.verify(runner)
        try bundleSigner.verify(bundle)
        guard
            FunctionalBytes.digest(
                try FunctionalPinnedPath(runnerSigner.executable(runner), directory: false).read())
                == runnerExecutableSHA256,
            FunctionalBytes.digest(
                try FunctionalPinnedPath(bundleSigner.executable(bundle), directory: false).read())
                == bundleExecutableSHA256
        else { throw FunctionalFailure.invalid("actual XCTest signed executable bytes") }
        let source = try FunctionalPinnedPath(
            directory.appendingPathComponent("HostedFunctionalInstalledUITests.swift"),
            directory: false, privateMode: true, maximum: 1_048_576)
        let sourceBytes = try source.read()
        guard FunctionalBytes.digest(sourceBytes) == sourceSHA256,
            let sourceText = String(data: sourceBytes, encoding: .utf8),
            [
                "authorize-original-step", "complete-original-step", held.capability.sourceCommit,
                held.capability.session,
                issuer.publicKey.base64EncodedString(),
            ].allSatisfy({ sourceText.contains($0) }),
            FunctionalProducerBuild.recipes.values.allSatisfy({
                sourceText.contains(FunctionalBytes.digest($0))
            })
        else { throw FunctionalFailure.invalid("actual source-built XCTest boundary bytes") }
        let invocationDirectory = directory.appendingPathComponent("invocations")
        var state = stat()
        if lstat(invocationDirectory.path, &state) != 0 {
            guard errno == ENOENT, mkdir(invocationDirectory.path, 0o700) == 0 else {
                throw FunctionalFailure.invalid("source-owned XCTest invocation directory")
            }
        }
        let invocationParent = try FunctionalPinnedPath(
            invocationDirectory, directory: true, privateMode: true)
        let invocationBytes = try issuer.seal([
            "schema": 1, "sourceCommit": issuer.sourceCommit, "session": issuer.session,
            "owner": held.capability.owner, "phase": held.capability.phase,
            "presentationID": held.presentationID, "capabilitySHA256": held.capabilitySHA256,
            "recipeSHA256": FunctionalBytes.digest(recipe),
            "sourceSHA256": sourceSHA256, "fixtureRoot": held.capability.fixtureRoot,
            "hostIdentifier": held.capability.hostIdentifier,
            "windowTitle": "Synthetic functional " + held.capability.owner + " "
                + held.capability.phase + " " + held.capability.session,
            "steps": steps,
            "ownedPaths": Dictionary(
                uniqueKeysWithValues: held.capability.ownedPaths.map { ($0.name, $0.path) }),
        ])
        let invocationURL = invocationDirectory.appendingPathComponent(
            held.capability.owner + "-" + held.capability.phase + ".json")
        let descriptor = open(
            invocationURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw FunctionalFailure.invalid("source-owned XCTest invocation creation")
        }
        let written = invocationBytes.withUnsafeBytes {
            write(descriptor, $0.baseAddress, $0.count)
        }
        let synced = fsync(descriptor)
        let closed = close(descriptor)
        guard written == invocationBytes.count, synced == 0, closed == 0 else {
            throw FunctionalFailure.invalid("source-owned XCTest invocation publication")
        }
        try invocationParent.requireCurrent()
        let invocation = try FunctionalPinnedPath(
            invocationURL, directory: false, privateMode: true, maximum: 1_048_576)
        guard try invocation.read() == invocationBytes else {
            throw FunctionalFailure.invalid("source-owned XCTest invocation bytes")
        }
        self.invocation = invocation
        invocationPath = invocationURL.path
        self.held = held
        self.runner = runner
        self.bundle = bundle
        self.runnerSigner = runnerSigner
        self.bundleSigner = bundleSigner
        self.source = source
        self.files = try FunctionalHeldPresentation.pinTree(runner)
        recipeSHA256 = FunctionalBytes.digest(recipe)
        stepCount = steps.count
        self.sourceSHA256 = sourceSHA256
        self.runnerExecutableSHA256 = runnerExecutableSHA256
    }

    func receive(
        operation: String, caller: FunctionalBirth, message: [String: Any],
        journal: FunctionalRequestJournal
    ) throws -> [String: Any] {
        var fields: Set<String> = [
            "schema", "sourceCommit", "session", "requestID", "operation", "owner", "phase",
            "stepIndex", "presentationID", "capabilitySHA256", "stepSHA256",
        ]
        if held.capability.owner == "calendar" { fields.insert("localControl") }
        try FunctionalBytes.exact(
            message,
            operation == "authorize-original-step" ? fields : fields.union(["authorizationID"]))
        let index = nextIndex
        let expectedStep = try held.originalStep(index: index)
        let stepSHA256 = FunctionalBytes.digest(try FunctionalBytes.canonical(expectedStep))
        guard message["phase"] as? String == held.capability.phase,
            try FunctionalBytes.integer(message, "stepIndex") == index,
            message["presentationID"] as? String == held.presentationID,
            message["capabilitySHA256"] as? String == held.capabilitySHA256,
            message["stepSHA256"] as? String == stepSHA256,
            caller.executable == (try runnerSigner.executable(runner)).path,
            caller.executableSHA256 == runnerExecutableSHA256, !completed
        else { throw FunctionalFailure.invalid("source-built XCTest actor correlation") }
        let localSnapshot: HostedFunctionalCalendarControlSnapshot?
        if held.capability.owner == "calendar" {
            guard index == 0, stepCount == 1, expectedStep["role"] as? String == "button",
                expectedStep["label"] as? String == "Show event details",
                expectedStep["selector"] as? String == "help",
                expectedStep["action"] as? String == "click",
                expectedStep["value"] is NSNull,
                let local = message["localControl"] as? [String: Any]
            else { throw FunctionalFailure.invalid("finite original Calendar local control") }
            localSnapshot = try HostedFunctionalCalendarControlSnapshot.decode(
                FunctionalBytes.canonical(local))
        } else {
            localSnapshot = nil
        }
        try requireArtifacts()
        try runnerSigner.verify(runner, birth: caller)
        try held.requireCurrent()
        if operation == "authorize-original-step" {
            guard (birth == nil || birth == caller), authorizationID == nil,
                authorizationEnvelope == nil
            else { throw FunctionalFailure.invalid("replayed XCTest action authorization") }
            birth = caller
            authorizationID = UUID().uuidString.lowercased()
            firstEventOrdinal = journal.records.count
            localBefore = localSnapshot
        } else {
            guard operation == "complete-original-step", caller == birth,
                message["authorizationID"] as? String == authorizationID,
                let firstEventOrdinal, journal.records.count >= firstEventOrdinal
            else { throw FunctionalFailure.invalid("unobserved XCTest action completion boundary") }
            if held.capability.owner == "calendar" {
                guard let localBefore, let localSnapshot else {
                    throw FunctionalFailure.invalid("missing actual Calendar local snapshots")
                }
                localObservations.append((index, localBefore, localSnapshot))
                self.localBefore = nil
            }
            try held.completeOriginalStep(index: index, digest: stepSHA256)
        }
        guard let authorizationID, let firstEventOrdinal else {
            throw FunctionalFailure.invalid("missing actual actor admission")
        }
        var result: [String: Any] = [
            "authorizationID": authorizationID, "actor": caller.object, "stepIndex": index,
            "stepSHA256": stepSHA256, "sourceSHA256": sourceSHA256,
            "presentationID": held.presentationID,
            "capabilitySHA256": held.capabilitySHA256, "firstEventOrdinal": firstEventOrdinal,
            "lastEventOrdinal": journal.records.count,
        ]
        if let localSnapshot {
            result["localControlSHA256"] = FunctionalBytes.digest(localSnapshot.bytes)
        }
        return result
    }

    func bindLocalObservationStart(_ sequence: Int) {
        localStartSequence = sequence
    }

    func localObservationStart() throws -> Int {
        guard held.capability.owner == "calendar", let localStartSequence, localStartSequence > 0
        else {
            throw FunctionalFailure.invalid("actual Calendar local observation sequence")
        }
        return localStartSequence
    }

    func observedCalendarControl() throws -> (
        before: HostedFunctionalCalendarControlSnapshot,
        after: HostedFunctionalCalendarControlSnapshot
    ) {
        guard held.capability.owner == "calendar", stepCount == 1, localObservations.count == 1,
            let observation = localObservations.first, observation.index == 0, localBefore == nil
        else {
            throw FunctionalFailure.invalid("incomplete actual Calendar local control observations")
        }
        try requireFinished()
        return (observation.before, observation.after)
    }

    func retainEnvelope(operation: String, bytes: Data) throws {
        if operation == "authorize-original-step" {
            guard authorizationID != nil, authorizationEnvelope == nil, !completed else {
                throw FunctionalFailure.invalid("duplicate actual actor authorization envelope")
            }
            authorizationEnvelope = bytes
        } else {
            guard operation == "complete-original-step", let authorizationEnvelope,
                completionEnvelope == nil, !completed
            else { throw FunctionalFailure.invalid("duplicate actual actor completion envelope") }
            completionEnvelope = bytes
            issuedObservations.append([
                "stepIndex": nextIndex,
                "authorization": try FunctionalBytes.object(authorizationEnvelope),
                "completion": try FunctionalBytes.object(bytes),
            ])
            nextIndex += 1
            completed = nextIndex == stepCount
            authorizationID = nil
            firstEventOrdinal = nil
            self.authorizationEnvelope = nil
            completionEnvelope = nil
        }
    }

    var currentAuthorizationID: String? { authorizationID }
    var currentStepIndex: Int? { authorizationID == nil ? nil : nextIndex }

    func observations() throws -> [String: Any] {
        guard issuedObservations.count == stepCount else {
            throw FunctionalFailure.invalid("unobserved complete XCTest recipe boundaries")
        }
        try requireFinished()
        return ["steps": issuedObservations]
    }

    func requireFinished() throws {
        guard completed, let birth else {
            throw FunctionalFailure.invalid("incomplete actual source-built XCTest actor")
        }
        try requireArtifacts()
        try birth.requireAbsent()
    }

    private func requireArtifacts() throws {
        try invocation.requireCurrent()
        try source.requireCurrent()
        guard FunctionalBytes.digest(try source.read()) == sourceSHA256,
            try FunctionalHeldPresentation.treePaths(runner) == files.map({ $0.0.url.path })
        else {
            throw FunctionalFailure.invalid("XCTest source or signed artifact changed")
        }
        for (path, hash) in files {
            guard FunctionalBytes.digest(try path.read()) == hash else {
                throw FunctionalFailure.invalid("XCTest signed bytes changed")
            }
        }
        try runnerSigner.verify(runner)
        try bundleSigner.verify(bundle)
    }
}

@MainActor
final class FunctionalSavedGeneration {
    let owner: String
    let phase: String
    let reader: FunctionalOwnerSavedReader
    let persistence: FunctionalPersistence
    let baselineClaim: [String: Any]
    private let root: FunctionalPinnedPath
    private let issuer: FunctionalIssuer
    private let baselineRaw: FunctionalOwnerSavedReader.RawObservation
    private(set) var finalObservation: FunctionalOwnerSavedReader.RawObservation?
    private(set) var beforeRequestClaim: [String: Any]?
    private(set) var finalPersistence: FunctionalPersistence.Observation?
    private var localControlAuthorizationID: String?

    init(
        owner: String, phase: String, root: FunctionalPinnedPath, issuer: FunctionalIssuer,
        definition: Data, sequence: Int, previous: FunctionalOwnerSavedReader.RawObservation?
    ) throws {
        let reader = try FunctionalOwnerSavedReader(
            owner: owner, phase: phase, root: root,
            session: issuer.session, hostIdentifier: FunctionalProducerBuild.hostIdentifier,
            definition: definition)
        if let previous { try reader.requirePreserved(since: previous) }
        let raw = try reader.observeSentinels()
        let persistence = FunctionalPersistence(
            reader: { try reader.read() }, initialSaved: reader.initialSaved)
        let captured = try persistence.captureBeforeConstruction(sequence: sequence)
        try reader.requireUnchanged(since: raw)
        self.owner = owner
        self.phase = phase
        self.root = root
        self.issuer = issuer
        self.reader = reader
        self.persistence = persistence
        baselineRaw = raw
        baselineClaim = [
            "schema": 1, "sourceCommit": issuer.sourceCommit, "session": issuer.session,
            "owner": owner, "phase": phase, "definitionSHA256": reader.definitionSHA256,
            "baseline": captured.object, "raw": raw.object,
            "saved": captured.bytes?.base64EncodedString() as Any? ?? NSNull(),
        ]
    }

    func bindLoaded(held: FunctionalHeldPresentation, sequence: Int) throws {
        guard held.capability.owner == owner, held.capability.phase == phase else {
            throw FunctionalFailure.invalid("foreign saved generation load")
        }
        try reader.requireUnchanged(since: baselineRaw)
        try persistence.bindLoaded(
            capabilitySHA256: held.capabilitySHA256, engine: held.engine, ui: held.ui,
            sequence: sequence)
    }

    func beforeFirstRequest(_ token: String) throws {
        try reader.requireUnchanged(since: baselineRaw)
        beforeRequestClaim = try persistence.beforeFirstRequest(token)
    }

    func beforeLocalControl(_ authorizationID: String, held: FunctionalHeldPresentation) throws {
        guard owner == "calendar", held.capability.owner == owner, held.capability.phase == phase,
            FunctionalBytes.uuid(authorizationID), localControlAuthorizationID == nil,
            reader.initialSaved == nil, reader.finalSaved == nil,
            persistence.baseline?.bytes == nil,
            persistence.firstRequestID == nil, persistence.loadSequence != nil,
            try reader.read() == nil
        else { throw FunctionalFailure.invalid("actual stateless Calendar local baseline") }
        try held.requireCurrent()
        try reader.requireUnchanged(since: baselineRaw)
        localControlAuthorizationID = authorizationID
    }

    func readSaved(sequence: Int, held: FunctionalHeldPresentation) throws -> [String: Any] {
        try held.requireCurrent()
        let observation: FunctionalPersistence.Observation
        if owner == "calendar" {
            guard localControlAuthorizationID != nil, let load = persistence.loadSequence,
                sequence > load,
                finalPersistence == nil, reader.initialSaved == nil, reader.finalSaved == nil,
                persistence.firstRequestID == nil, try reader.read() == nil
            else {
                throw FunctionalFailure.invalid("actual stateless Calendar saved observation")
            }
            try reader.requireUnchanged(since: baselineRaw)
            observation = .init(sequence: sequence, bytes: nil, expectedBytes: nil)
        } else {
            observation = try persistence.readSaved(sequence: sequence, expected: reader.finalSaved)
        }
        finalPersistence = observation
        let raw = try reader.observeSentinels()
        guard raw.saved == reader.finalSaved else {
            throw FunctionalFailure.invalid("actual raw final saved state")
        }
        finalObservation = raw
        return [
            "schema": 1, "sourceCommit": issuer.sourceCommit, "session": issuer.session,
            "owner": owner, "phase": phase, "definitionSHA256": reader.definitionSHA256,
            "capabilitySHA256": held.capabilitySHA256, "observation": observation.object,
            "raw": raw.object,
            "beforeFirstRequest": beforeRequestClaim as Any? ?? NSNull(),
            "saved": raw.saved?.base64EncodedString() as Any? ?? NSNull(),
        ]
    }

    static func prepareDirectories(
        owner: String, phase: WorkerFixtureFilePhase, root: FunctionalPinnedPath,
        issuer: FunctionalIssuer, policy: WorkerFixtureRolePolicy, definition: Data
    ) throws {
        try root.requireCurrent()
        var directories = Set(
            try FunctionalOwnerSavedReader.requiredParentDirectories(
                owner: owner, phase: phase.rawValue,
                root: root.url.path, session: issuer.session,
                hostIdentifier: FunctionalProducerBuild.hostIdentifier, definition: definition))
        directories.insert(root.url.path + "/" + owner + "-home")
        directories.insert(
            root.url.path + "/Edith Tests/worker-" + issuer.session + "/Data/" + owner)
        let resolved = try policy.resolvedOwnedPaths(
            root: root.url.path, session: issuer.session, phase: phase)
        for path in Array(directories) {
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            while parent.path != root.url.path {
                guard parent.path.hasPrefix(root.url.path + "/") else {
                    throw FunctionalFailure.invalid("source bootstrap directory outside root")
                }
                directories.insert(parent.path)
                parent.deleteLastPathComponent()
            }
        }
        for entry in resolved {
            var parents = [URL(fileURLWithPath: entry.path).deletingLastPathComponent()]
            if entry.scope.kind == .directory {
                directories.insert(entry.path)
                for components in entry.scope.immutableFiles.map(\.components)
                    + entry.scope.mutableFiles.map(\.components)
                {
                    parents.append(
                        URL(fileURLWithPath: entry.path).appendingPathComponent(
                            components.joined(separator: "/")
                        ).deletingLastPathComponent())
                }
            }
            for var parent in parents {
                while parent.path != root.url.path {
                    guard parent.path.hasPrefix(root.url.path + "/") else {
                        throw FunctionalFailure.invalid(
                            "finite source namespace directory outside root")
                    }
                    directories.insert(parent.path)
                    parent.deleteLastPathComponent()
                }
            }
        }
        for path in directories.sorted(by: {
            ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1)
        }) {
            let url = URL(fileURLWithPath: path)
            guard url.standardizedFileURL.path == path, path.hasPrefix(root.url.path + "/") else {
                throw FunctionalFailure.invalid("finite source namespace canonical directory")
            }
            _ = try FunctionalPinnedPath(url.deletingLastPathComponent(), directory: true)
            var state = stat()
            if lstat(path, &state) != 0 {
                guard errno == ENOENT, mkdir(path, 0o700) == 0 else {
                    throw FunctionalFailure.invalid("source namespace directory creation")
                }
            }
            _ = try FunctionalPinnedPath(url, directory: true, privateMode: true)
        }
        try root.requireCurrent()
    }
}
