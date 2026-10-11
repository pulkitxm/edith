import CryptoKit
import Foundation
import Testing
@testable import WorkerFixtureSupport

struct WorkerFixtureUIContractTests {
    private let session = "12345678-1234-4123-8123-123456789abc"
    private let source = String(repeating: "a", count: 40)
    private let hash = String(repeating: "b", count: 64)

    private var root: String { "/private/synthetic/functional-fixture-" + session }
    private var host: String { "com.pulkit.edith.tests.worker-" + session }
    private var worker: String {
        root
            + "/Extensions/plugins/edith-host-2/arm64/1.0.0/plugins/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex"
    }

    private func object() -> [String: Any] {
        func peer(_ pid: Int, executable: String) -> [String: Any] {
            [
                "pid": pid, "birthSeconds": 1000, "birthMicroseconds": pid, "uid": 501,
                "executable": executable, "executableSHA256": hash,
            ]
        }
        return [
            "schema": 1, "sourceCommit": source, "session": session, "owner": "plugins",
            "phase": "initial", "presentationID": session, "location": "main", "section": "plugins",
            "capabilitySHA256": hash, "root": root, "hostIdentifier": host,
            "home": root + "/plugins-home", "dataDirectory": root + "/data/plugins",
            "workerPath": worker,
            "rolePath": worker + "/Contents/Resources/Payload/plugins/app.bundle",
            "version": "1.0.0", "hostABI": "edith-host-2", "packageSHA256": hash,
            "producer": peer(10, executable: root + "/Producer/functional-producer"),
            "engine": peer(11, executable: worker + "/Contents/MacOS/Edith"),
            "ui": peer(12, executable: worker + "/Contents/MacOS/Edith"),
        ]
    }

    private func seal(_ object: [String: Any], key: Curve25519.Signing.PrivateKey) throws -> Data {
        let payload = try WorkerFixtureUIContract.canonicalJSON(object)
        return try WorkerFixtureUIContract.canonicalJSON([
            "schema": 1, "payload": String(decoding: payload, as: UTF8.self),
            "signature": try key.signature(for: payload).base64EncodedString(),
        ])
    }

    private func validate(_ descriptor: WorkerFixtureUIContract) throws {
        let original = object()
        func process(_ name: String) throws -> WorkerFixtureUIProcess {
            try JSONDecoder().decode(
                WorkerFixtureUIProcess.self,
                from: WorkerFixtureUIContract.canonicalJSON(original[name] as! [String: Any]))
        }
        try descriptor.validate(
            sourceCommit: source, session: session, owner: "plugins", presentationID: session,
            phase: "initial", location: "main", section: "plugins", capabilitySHA256: hash,
            root: root, dataDirectory: root + "/data/plugins", workerPath: worker,
            rolePath: worker + "/Contents/Resources/Payload/plugins/app.bundle", version: "1.0.0",
            uid: 501, producer: process("producer"), engine: process("engine"), ui: process("ui"))
    }

    @Test func independentlyPinnedIssuerAdmitsExactNativeGeneration() throws {
        let key = Curve25519.Signing.PrivateKey()
        let bytes = try seal(object(), key: key)
        let descriptor = try WorkerFixtureUIContract.verify(
            bytes, issuerKey: key.publicKey.rawRepresentation)
        try validate(descriptor)
        #expect(descriptor.engine.pid != descriptor.ui.pid)
        #expect(WorkerFixtureUITrustAnchor.admitted == nil)
    }

    @Test func signedClaimsCannotSelectTrustOrReplaceCurrentIdentity() throws {
        let key = Curve25519.Signing.PrivateKey()
        let original = object()
        for patch: [String: Any] in [
            ["issuerKey": key.publicKey.rawRepresentation.base64EncodedString()],
            ["schema": true], ["schema": 1.5], ["sourceCommit": String(repeating: "c", count: 40)],
            ["phase": "updated"], ["capabilitySHA256": String(repeating: "c", count: 64)],
            ["owner": "studio"], ["home": root + "/foreign-home"],
            ["dataDirectory": root + "/foreign-data"], ["presentationID": "foreign"],
            ["location": "settings"], ["section": "studio"],
            ["rolePath": root + "/outside.bundle"], ["version": "1.1.0"],
        ] {
            var changed = original
            changed.merge(patch) { _, value in value }
            #expect(throws: (any Error).self) {
                try validate(
                    WorkerFixtureUIContract.verify(
                        seal(changed, key: key), issuerKey: key.publicKey.rawRepresentation))
            }
        }
        for name in ["producer", "engine", "ui"] {
            for patch: [String: Any] in [
                ["pid": 99], ["birthSeconds": 2000], ["birthMicroseconds": 10_000],
                ["uid": 502], ["executableSHA256": String(repeating: "c", count: 64)],
                ["executable": root + "/other"], ["issuer": "foreign"],
            ] {
                var changed = original
                var peer = changed[name] as! [String: Any]
                peer.merge(patch) { _, value in value }
                changed[name] = peer
                #expect(throws: (any Error).self) {
                    try validate(
                        WorkerFixtureUIContract.verify(
                            seal(changed, key: key), issuerKey: key.publicKey.rawRepresentation))
                }
            }
        }
        let foreign = Curve25519.Signing.PrivateKey()
        #expect(throws: (any Error).self) {
            try WorkerFixtureUIContract.verify(
                seal(original, key: foreign), issuerKey: key.publicKey.rawRepresentation)
        }
    }

    @Test func duplicateDecodedFieldsAndTamperedBytesFailBeforeAdmission() throws {
        let key = Curve25519.Signing.PrivateKey()
        let canonical = String(
            decoding: try WorkerFixtureUIContract.canonicalJSON(object()), as: UTF8.self)
        for prefix in ["\"schema\":1,", "\"\\u0073chema\":1,"] {
            let payload = Data(("{" + prefix + canonical.dropFirst()).utf8)
            let envelope = try WorkerFixtureUIContract.canonicalJSON([
                "schema": 1, "payload": String(decoding: payload, as: UTF8.self),
                "signature": try key.signature(for: payload).base64EncodedString(),
            ])
            #expect(throws: (any Error).self) {
                try WorkerFixtureUIContract.verify(
                    envelope, issuerKey: key.publicKey.rawRepresentation)
            }
        }
        let bytes = try seal(object(), key: key)
        let tampered = Data(
            String(decoding: bytes, as: UTF8.self).replacingOccurrences(
                of: "plugins", with: "foreign"
            ).utf8)
        #expect(throws: (any Error).self) {
            try WorkerFixtureUIContract.verify(tampered, issuerKey: key.publicKey.rawRepresentation)
        }
    }

    @Test func strictUIContextRejectsEngineRolesAndBooleanCoercion() throws {
        let identifier = host + ".extension.plugins.worker"
        let context: [String: Any] = [
            "hostIdentifier": host, "remoteUI": true, "uiOnly": false,
            "extensionID": "plugins", "location": "main", "section": "plugins",
            "presentationID": session.uppercased(), "defaultsSuite": identifier,
        ]
        let environment = [
            "EDITH_APPLICATION_IDENTIFIER": host,
            "EDITH_EXTENSION_ID": "plugins", "EDITH_SHARED_DEFAULTS_SUITE": identifier,
        ]
        try WorkerFixtureUIContract.validateUIContext(
            context as NSDictionary,
            environment: environment, owner: "plugins", workerIdentifier: identifier)
        for patch: [String: Any] in [
            ["remoteUI": 1], ["remoteUI": false], ["uiOnly": 0], ["uiOnly": true],
            ["hostIdentifier": "com.pulkit.edith"], ["defaultsSuite": host + ".extensions.plugins"],
            ["presentationID": "foreign"], ["extensionID": "studio"], ["location": "foreign"],
        ] {
            var changed = context
            changed.merge(patch) { _, value in value }
            #expect(throws: (any Error).self) {
                try WorkerFixtureUIContract.validateUIContext(
                    changed as NSDictionary,
                    environment: environment, owner: "plugins", workerIdentifier: identifier)
            }
        }
    }

    @Test func trustPinsSeparateSignersAndExactOwnedExecutable() throws {
        func trust(
            producer: String? = nil, sourceCommit: String? = nil, issuer: Data? = nil,
            hostExecutableSHA256: String? = nil, roleCertificate: Data? = nil
        ) throws -> WorkerFixtureUITrust {
            try WorkerFixtureUITrust(
                sourceCommit: sourceCommit ?? source, session: session, root: root,
                issuerKey: issuer ?? Data(repeating: 1, count: 32),
                hostExecutableSHA256: hostExecutableSHA256 ?? hash,
                hostRequirement: "identifier \"com.pulkit.edith.tests\"",
                hostCertificateSHA256: Data(repeating: 2, count: 32),
                workerCertificateSHA256: Data(repeating: 3, count: 32),
                roleCertificateSHA256: roleCertificate ?? Data(repeating: 4, count: 32),
                producerExecutable: producer ?? root + "/Producer/functional-producer",
                producerExecutableSHA256: hash)
        }
        let admitted = try trust()
        #expect(admitted.hostCertificateSHA256 != admitted.roleCertificateSHA256)
        #expect(admitted.workerCertificateSHA256 != admitted.roleCertificateSHA256)
        #expect(throws: (any Error).self) { try trust(producer: "/usr/bin/true") }
        #expect(throws: (any Error).self) { try trust(sourceCommit: "foreign") }
        #expect(throws: (any Error).self) { try trust(issuer: Data()) }
        #expect(throws: (any Error).self) { try trust(hostExecutableSHA256: "foreign") }
        #expect(throws: (any Error).self) { try trust(roleCertificate: Data()) }
    }
}
