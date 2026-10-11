import CryptoKit
import Darwin
import Foundation

@MainActor
enum FunctionalHostBootstrap {
    static func rendezvous(operation: String, owner: String, phase: String? = nil, fields: [String: Any]) throws -> [String: Any] {
        guard HostedFunctionalActionContext.owners.contains(owner),
            phase == nil || ["initial", "updated", "reinstalled"].contains(phase!),
            ["admit-starting-reservation", "prepared-original-peers", "admit-engine", "admit-ui", "before-original-request", "after-original-response", "native-emitted-reply", "owner-joined", "native-stop-prepared", "engine-stop-observed", "native-stop-observed"].contains(operation),
            !fields.keys.contains(where: { ["schema", "sourceCommit", "session", "owner", "phase", "operation", "requestID"].contains($0) })
        else { throw FunctionalFailure.invalid("source-owned bootstrap operation") }
        let root = try FunctionalPinnedPath(URL(fileURLWithPath: FunctionalHostBuild.root), directory: true, privateMode: true)
        try root.requireCurrent()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let descriptor = try FunctionalSocketWire.connect(path: root.url.path + "/p.sock", deadline: deadline)
        defer { close(descriptor) }
        let peer = try FunctionalSocketPeer(descriptor: descriptor)
        guard peer.birth.executable == FunctionalHostBuild.producerExecutable,
            peer.birth.executableSHA256 == FunctionalHostBuild.producerExecutableSHA256
        else { throw FunctionalFailure.invalid("independently compiled producer pin") }
        try FunctionalSigner(identifier: FunctionalHostBuild.producerIdentifier,
            certificateSHA256: FunctionalHostBuild.certificateSHA256,
            requirement: "identifier \"" + FunctionalHostBuild.producerIdentifier + "\"")
            .verify(URL(fileURLWithPath: peer.birth.executable), birth: peer.birth)
        let requestID = UUID().uuidString.lowercased()
        var request = fields.merging([
            "schema": 1, "sourceCommit": FunctionalHostBuild.sourceCommit,
            "session": FunctionalHostBuild.session, "owner": owner,
            "operation": operation, "requestID": requestID,
        ]) { _, new in new }
        if let phase { request["phase"] = phase }
        try FunctionalSocketWire.writeFrame(FunctionalBytes.canonical(request), descriptor: descriptor, deadline: deadline)
        let response = try verifyEnvelope(FunctionalSocketWire.readFrame(descriptor, deadline: deadline))
        try peer.birth.requireCurrent()
        try root.requireCurrent()
        guard response["requestID"] as? String == requestID,
            response["operation"] as? String == operation, response["owner"] as? String == owner,
            let observedPhase = response["phase"] as? String,
            ["initial", "updated", "reinstalled"].contains(observedPhase),
            phase == nil || observedPhase == phase
        else { throw FunctionalFailure.invalid("producer bootstrap response correlation") }
        return response
    }

    static func verifyEnvelope(_ bytes: Data) throws -> [String: Any] {
        let envelope = try FunctionalBytes.object(bytes)
        try FunctionalBytes.exact(envelope, ["schema", "payload", "signature"])
        guard try FunctionalBytes.integer(envelope, "schema") == 1,
            let payload = envelope["payload"] as? String,
            let signatureText = envelope["signature"] as? String,
            let signature = Data(base64Encoded: signatureText), signature.count == 64,
            signature.base64EncodedString() == signatureText,
            try Curve25519.Signing.PublicKey(rawRepresentation: FunctionalHostBuild.issuerPublicKey)
                .isValidSignature(signature, for: Data(payload.utf8))
        else { throw FunctionalFailure.invalid("compiled issuer signature") }
        let object = try FunctionalBytes.object(Data(payload.utf8))
        guard try FunctionalBytes.integer(object, "schema") == 1,
            object["sourceCommit"] as? String == FunctionalHostBuild.sourceCommit,
            object["session"] as? String == FunctionalHostBuild.session
        else { throw FunctionalFailure.invalid("compiled source bootstrap") }
        return object
    }
}
