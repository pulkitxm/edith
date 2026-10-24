import CryptoKit
import Foundation
#if SWIFT_PACKAGE
import FunctionalActionContract
#endif

enum FunctionalEvidenceSealing {
    struct StepInventory {
        let index: Int
        let beforeData: Data
        let afterData: Data
    }

    struct OwnerProof {
        let owner: String
        let caseSHA256: String
        let claimData: Data
        let observationData: Data
    }

    struct ProcessBirth: Encodable {
        let pid: Int32
        let birthSeconds: Int64
        let birthMicroseconds: Int32
        let uid: UInt32
        let executable: String
        let executableSHA256: String
    }

    struct QualifiedContext {
        let schema: Int
        let sourceCommit: String
        let mergeCommit: String
        let baseCommit: String
        let session: String
        let root: String
        let hostIdentifier: String
        let issuerPublicKey: String
        let issuerManifestSHA256: String
        let artifactSHA256: String
        let policySHA256: String
        let sourceSHA256: String
        let toolchainSHA256: String
        let runID: Int
        let jobID: Int
        let runAttempt: Int
        let workflowSHA256: String
        let producer: ProcessBirth
        let host: ProcessBirth
    }

    struct RetirementFacts {
        let hostAbsent: Bool
        let receiverJoined: Bool
        let signalsSent: Int
    }

    static let owners = [
        "keepAwake", "audioMixer", "focusDim", "hinge", "windowSweaters", "micMute",
        "keystrokeHighlight", "presenter", "colorPicker", "systemStats", "emoji",
        "homebrew", "calendar", "jev", "system", "timeLapse", "cleaner", "appMaintenance",
        "blitztree", "plugins", "notchShelf", "clipboard", "music", "docs", "latex",
        "companion", "terminal", "studio", "usage", "bifrost", "lidAwake", "attention",
        "machines", "downloads", "seoAudit", "virtualCamera", "codeStats", "herdr",
        "quinjet", "database", "socialManager",
    ]

    static func presentation(
        stage: FunctionalCollectedEvidence.CompletedStage,
        recipe: Data, definition: Data, inventories: [StepInventory], drainReceipt: Data
    ) throws -> Data {
        let cap = stage.capability
        let definitionBytes = definition
        _ = try FunctionalBytes.object(definitionBytes)
        let definition = try JSONDecoder().decode(
            FunctionalCollectedEvidence.Definition.self, from: definitionBytes)
        guard try encode(definition) == definitionBytes else {
            throw FunctionalFailure.invalid("exact compiled source definition")
        }
        let recipeObject = try FunctionalBytes.object(recipe)
        try FunctionalBytes.exact(
            recipeObject,
            ["schema", "owner", "location", "section", "operation", "steps", "sources"])
        guard definition.schema == 1, definition.owner == cap.owner,
            FunctionalBytes.digest(definitionBytes) == cap.caseSHA256,
            try FunctionalBytes.integer(recipeObject, "schema") == 1,
            recipeObject["owner"] as? String == cap.owner,
            recipeObject["operation"] as? String == cap.activationOperation,
            let steps = recipeObject["steps"] as? [[String: Any]],
            !steps.isEmpty, steps.count <= 16, inventories.count == steps.count,
            let selected = stage.journal.records.last,
            selected.request.operation == cap.activationOperation,
            selected.acknowledgement.success,
            stage.authoritative.sequence > selected.acknowledgement.sequence,
            FunctionalBytes.digest(stage.authoritative.bytes)
                == selected.transition.after.expectedSHA256,
            stage.authoritative.observationID != selected.request.requestID,
            stage.admission.admission.complete,
            stage.requestRecords.contains(where: {
                $0.token == selected.request.requestID && $0.event == .engineBefore
                    && $0.caller == cap.engine
            }),
            stage.requestRecords.contains(where: {
                $0.token == selected.request.requestID && $0.event == .engineAfter
                    && $0.caller == cap.engine && $0.outcome == true
            })
        else { throw FunctionalFailure.invalid("collected presentation bindings") }
        let capabilityData = try encode(cap)
        guard stage.journal.capabilitySHA256 == FunctionalBytes.digest(capabilityData),
            stage.journal.presentationID == stage.presentationID,
            FunctionalBytes.uuid(stage.presentationID),
            stage.presentationID == (try presentationID(capabilityData))
        else { throw FunctionalFailure.invalid("collected presentation identity") }
        let encodedInventories = try inventories.enumerated().map {
            position, item -> [String: Any] in
            guard item.index == position else {
                throw FunctionalFailure.invalid("original recipe inventory index")
            }
            let before = try inventory(item.beforeData, stage: stage)
            let after = try inventory(item.afterData, stage: stage)
            guard item.beforeData == item.afterData, item.beforeData == inventories[0].beforeData
            else {
                throw FunctionalFailure.invalid("unchanged original inventory through every step")
            }
            return ["index": item.index, "before": before, "after": after]
        }
        let drain = try FunctionalBytes.object(drainReceipt)
        try FunctionalBytes.exact(
            drain, ["births", "allTasksJoined", "birthsAbsent", "leasesReleased", "signalsSent"])
        guard let births = drain["births"] as? [[String: Any]],
            try FunctionalBytes.canonical(births) == encode([cap.engine, cap.ui]),
            try FunctionalBytes.boolean(drain, "allTasksJoined"),
            try FunctionalBytes.boolean(drain, "birthsAbsent"),
            try FunctionalBytes.boolean(drain, "leasesReleased"),
            try FunctionalBytes.integer(drain, "signalsSent") == 0,
            stage.drain.engineStop.signalAttempts.isEmpty,
            stage.drain.nativeStop.signalAttempts.isEmpty,
            stage.drain.nativeStop.joinedTasks == ["engine-receivers"],
            !stage.drain.cleanupStarted,
            Set(stage.drain.capturedLeaseTokens) == Set(stage.drain.releasedLeaseTokens),
            stage.drain.capturedLeaseTokens.count == stage.drain.releasedLeaseTokens.count,
            stage.drain.captured == [cap.engine, cap.ui],
            stage.drain.absent.count == stage.drain.captured.count,
            stage.drain.captured.allSatisfy({ stage.drain.absent.contains($0) })
        else { throw FunctionalFailure.invalid("actual collected presentation retirement") }
        let observed: [String: Any] = [
            "schema": 1, "authority": "independent-hosted-producer",
            "execution": "hosted-macos-native",
            "capabilitySHA256": stage.journal.capabilitySHA256,
            "recipeSHA256": FunctionalBytes.digest(recipe),
            "presentationID": stage.presentationID,
            "windowTitle": "Synthetic functional " + cap.owner + " " + cap.phase + " "
                + cap.session,
            "before": encodedInventories[0]["before"]!, "after": encodedInventories.last!["after"]!,
            "steps": steps, "stepInventories": encodedInventories,
            "mutation": [
                "origin": "authenticated-downloaded-ui-engine-receiver",
                "operation": selected.request.operation,
                "presentationID": stage.presentationID, "ui": try object(selected.ui),
                "engine": try object(selected.engine),
                "requestID": selected.request.requestID,
                "payloadSHA256": selected.request.payloadSHA256,
                "responseSHA256": selected.acknowledgement.responseSHA256,
                "success": selected.acknowledgement.success,
                "beforeAuthoritativeRead": selected.acknowledgement.sequence
                    < stage.authoritative.sequence,
            ],
            "authoritative": [
                "reader": selected.transition.reader, "kind": definition.observation.kind,
                "name": definition.observation.name,
                "observationID": stage.authoritative.observationID,
                "engine": try object(cap.engine),
                "observedSHA256": FunctionalBytes.digest(stage.authoritative.bytes),
                "expectedSHA256": selected.transition.after.expectedSHA256,
            ],
            "presentationClosed": try FunctionalBytes.boolean(drain, "birthsAbsent"),
            "leasesReleased": try FunctionalBytes.boolean(drain, "leasesReleased"),
        ]
        return try bounded(observed)
    }

    static func sealOwner(
        evidence: FunctionalCollectedEvidence.UnsignedEvidence, owner: String,
        caseSHA256: String, publicKey: Data, sign: (Data) throws -> Data
    ) throws -> OwnerProof {
        guard owners.contains(owner), FunctionalBytes.hex(caseSHA256, length: 64),
            evidence.claim["owner"] as? String == owner,
            evidence.claim["caseSHA256"] as? String == caseSHA256,
            evidence.journalPayloads.count == 3
        else { throw FunctionalFailure.invalid("collected owner seal binding") }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        let claimData = try seal(evidence.claim, key: key, sign: sign)
        let journalEnvelopes = try evidence.journalPayloads.map {
            payload -> FunctionalCollectedEvidence.JournalEnvelope in
            let envelope = try seal(FunctionalBytes.object(payload), key: key, sign: sign)
            let fields = try FunctionalBytes.object(envelope, maximum: 2_097_152)
            _ = try HostedFunctionalMutationJournal.verify(envelope, issuerKey: publicKey)
            return .init(
                schema: 1, payload: fields["payload"] as! String,
                signature: fields["signature"] as! String)
        }
        let observation = try evidence.observation(journalEnvelopes: journalEnvelopes)
        let observationData = try seal(observation, key: key, sign: sign)
        return OwnerProof(
            owner: owner, caseSHA256: caseSHA256, claimData: claimData,
            observationData: observationData)
    }

    static func aggregate(
        context: QualifiedContext, owners proofs: [OwnerProof], retirement: RetirementFacts,
        publicKey: Data
    ) throws -> Data {
        guard context.schema == 1,
            [context.sourceCommit, context.mergeCommit, context.baseCommit].allSatisfy({
                FunctionalBytes.hex($0, length: 40)
            }),
            context.sourceCommit != context.mergeCommit, FunctionalBytes.uuid(context.session),
            canonicalPath(context.root),
            context.root.hasSuffix("/functional-fixture-" + context.session),
            context.hostIdentifier == "com.pulkit.edith.tests.worker-" + context.session,
            publicKey.count == 32, context.issuerPublicKey == publicKey.base64EncodedString(),
            [
                context.issuerManifestSHA256, context.artifactSHA256, context.policySHA256,
                context.sourceSHA256, context.toolchainSHA256, context.workflowSHA256,
            ].allSatisfy({ FunctionalBytes.hex($0, length: 64) }),
            [context.runID, context.jobID, context.runAttempt].allSatisfy({
                $0 > 0 && $0 <= 9_007_199_254_740_991
            }),
            context.producer.uid == context.host.uid, context.producer.pid != context.host.pid,
            context.producer.executable == context.root + "/Producer/functional-producer",
            context.host.executable == context.root + "/Fixture.app/Contents/MacOS/Edith",
            proofs.map(\.owner) == owners, retirement.hostAbsent, retirement.receiverJoined,
            retirement.signalsSent == 0
        else { throw FunctionalFailure.invalid("qualified actual context and retirement") }
        try requireBirth(context.producer)
        try requireBirth(context.host)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        let records = try proofs.map { proof -> [String: Any] in
            guard FunctionalBytes.hex(proof.caseSHA256, length: 64) else {
                throw FunctionalFailure.invalid("qualified case hash")
            }
            for data in [proof.claimData, proof.observationData] {
                let payload = try verify(data, key: key)
                guard payload["owner"] as? String == proof.owner,
                    payload["caseSHA256"] as? String == proof.caseSHA256,
                    payload["sourceCommit"] as? String == context.sourceCommit,
                    payload["session"] as? String == context.session
                else { throw FunctionalFailure.invalid("original owner envelope scope") }
            }
            let observation = try verify(proof.observationData, key: key)
            guard let stages = observation["stages"] as? [[String: Any]], stages.count == 3 else {
                throw FunctionalFailure.invalid("qualified three original journals")
            }
            for stage in stages {
                guard let envelope = stage["mutationJournal"] as? [String: Any] else {
                    throw FunctionalFailure.invalid("qualified original journal envelope")
                }
                let journal = try HostedFunctionalMutationJournal.verify(
                    FunctionalBytes.canonical(envelope), issuerKey: publicKey)
                guard journal.owner == proof.owner, journal.sourceCommit == context.sourceCommit,
                    journal.session == context.session
                else {
                    throw FunctionalFailure.invalid("qualified original journal scope")
                }
            }
            return [
                "owner": proof.owner, "caseSHA256": proof.caseSHA256,
                "claimSHA256": FunctionalBytes.digest(proof.claimData),
                "observationSHA256": FunctionalBytes.digest(proof.observationData),
            ]
        }
        return try bounded([
            "schema": context.schema, "kind": "qualified-evidence",
            "sourceCommit": context.sourceCommit,
            "mergeCommit": context.mergeCommit, "baseCommit": context.baseCommit,
            "session": context.session,
            "root": context.root, "hostIdentifier": context.hostIdentifier,
            "issuerPublicKey": context.issuerPublicKey,
            "issuerManifestSHA256": context.issuerManifestSHA256,
            "artifactSHA256": context.artifactSHA256,
            "policySHA256": context.policySHA256, "sourceSHA256": context.sourceSHA256,
            "toolchainSHA256": context.toolchainSHA256,
            "runID": context.runID, "jobID": context.jobID, "runAttempt": context.runAttempt,
            "workflowSHA256": context.workflowSHA256,
            "producer": try object(context.producer), "host": try object(context.host),
            "owners": records,
            "retirement": [
                "hostAbsent": retirement.hostAbsent, "receiverJoined": retirement.receiverJoined,
                "signalsSent": retirement.signalsSent,
            ],
        ])
    }

    static func presentationID(_ capabilityData: Data) throws -> String {
        let capability = try FunctionalBytes.object(capabilityData)
        let template = capability.filter { !["engine", "ui"].contains($0.key) }
        var bytes = Array(SHA256.hash(data: try FunctionalBytes.canonical(template)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let boundaries = [0, 8, 12, 16, 20, 32]
        return zip(boundaries, boundaries.dropFirst()).map { start, end in
            String(
                hex[
                    hex.index(
                        hex.startIndex, offsetBy: start)..<hex.index(hex.startIndex, offsetBy: end)]
            )
        }.joined(separator: "-")
    }

    private static func inventory(_ data: Data, stage: FunctionalCollectedEvidence.CompletedStage)
        throws -> [String: Any]
    {
        let value = try FunctionalBytes.object(data)
        try FunctionalBytes.exact(
            value,
            [
                "sourceCommit", "sourceClean", "heldRootPinned", "heldDescriptorPinned",
                "hostSignatureVerified",
                "workerSignatureVerified", "roleSignatureVerified", "rolePayloadUnchanged",
                "factoryOverlay", "originalFactoriesUnchanged",
                "originalControlsUnchanged", "hostABI", "version", "packageSHA256",
                "bundleTreeSHA256", "engine", "ui", "presentationID",
            ])
        for field in [
            "sourceClean", "heldRootPinned", "heldDescriptorPinned", "hostSignatureVerified",
            "workerSignatureVerified",
            "roleSignatureVerified", "rolePayloadUnchanged", "originalFactoriesUnchanged",
            "originalControlsUnchanged",
        ] {
            guard try FunctionalBytes.boolean(value, field) else {
                throw FunctionalFailure.invalid("actual inventory admission")
            }
        }
        let cap = stage.capability
        guard try !FunctionalBytes.boolean(value, "factoryOverlay"),
            value["sourceCommit"] as? String == cap.sourceCommit,
            value["hostABI"] as? String == cap.hostABI, value["version"] as? String == cap.version,
            value["packageSHA256"] as? String == cap.packageSHA256,
            value["presentationID"] as? String == stage.presentationID,
            let tree = value["bundleTreeSHA256"] as? String, FunctionalBytes.hex(tree, length: 64),
            let engine = value["engine"] as? [String: Any], let ui = value["ui"] as? [String: Any],
            try FunctionalBytes.canonical(engine) == encode(cap.engine),
            try FunctionalBytes.canonical(ui) == encode(cap.ui)
        else { throw FunctionalFailure.invalid("actual inventory capability binding") }
        return value
    }

    private static func seal(
        _ object: [String: Any], key: Curve25519.Signing.PublicKey, sign: (Data) throws -> Data
    ) throws -> Data {
        let payload = try bounded(object)
        let envelope = try sign(payload)
        let verified = try verify(envelope, key: key)
        guard try FunctionalBytes.canonical(verified) == payload else {
            throw FunctionalFailure.invalid("supplied issuer exact payload")
        }
        return envelope
    }

    private static func verify(_ data: Data, key: Curve25519.Signing.PublicKey) throws -> [String:
        Any]
    {
        let envelope = try FunctionalBytes.object(data, maximum: 2_097_152)
        try FunctionalBytes.exact(envelope, ["schema", "payload", "signature"])
        guard try FunctionalBytes.integer(envelope, "schema") == 1,
            let text = envelope["payload"] as? String,
            let encoded = envelope["signature"] as? String,
            let signature = Data(base64Encoded: encoded), signature.count == 64,
            signature.base64EncodedString() == encoded,
            key.isValidSignature(signature, for: Data(text.utf8))
        else { throw FunctionalFailure.invalid("original issuer envelope signature") }
        return try FunctionalBytes.object(Data(text.utf8))
    }

    private static func requireBirth(_ birth: ProcessBirth) throws {
        guard birth.pid > 1, birth.birthSeconds > 0, birth.birthSeconds <= 9_007_199_254_740_991,
            (0..<1_000_000).contains(birth.birthMicroseconds), canonicalPath(birth.executable),
            FunctionalBytes.hex(birth.executableSHA256, length: 64)
        else { throw FunctionalFailure.invalid("qualified captured process birth") }
    }

    private static func canonicalPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096
            && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            && !value.dropFirst().split(separator: "/", omittingEmptySubsequences: false).contains(
                where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func bounded(_ value: [String: Any]) throws -> Data {
        let data = try FunctionalBytes.canonical(value)
        guard !data.isEmpty, data.count <= 1_048_576 else {
            throw FunctionalFailure.invalid("bounded original evidence document")
        }
        return data
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
