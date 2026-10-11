import CryptoKit
import Foundation
import Testing
@testable import WorkerFixtureSupport

@MainActor struct WorkerFixtureEngineContractTests {
    private let session = "12345678-1234-4123-8123-123456789abc"
    private let source = String(repeating: "a", count: 40)
    private let hash = String(repeating: "b", count: 64)
    private var root: String { "/private/synthetic/functional-fixture-" + session }
    private var worker: String {
        root
            + "/Extensions/studio/edith-host-2/arm64/1.0.0/studio/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex"
    }
    private func trust(_ key: Data) throws -> WorkerFixtureUITrust {
        try WorkerFixtureUITrust(
            sourceCommit: source, session: session, root: root, issuerKey: key,
            hostExecutableSHA256: hash, hostRequirement: "identifier synthetic.fixture",
            hostCertificateSHA256: Data(repeating: 1, count: 32),
            workerCertificateSHA256: Data(repeating: 2, count: 32),
            roleCertificateSHA256: Data(repeating: 3, count: 32),
            producerExecutable: root + "/Producer/functional-producer",
            producerExecutableSHA256: hash)
    }
    private func object() -> [String: Any] {
        func peer(_ pid: Int, _ path: String) -> [String: Any] {
            [
                "pid": pid, "birthSeconds": 1000, "birthMicroseconds": pid, "uid": 501,
                "executable": path, "executableSHA256": hash,
            ]
        }
        return [
            "schema": 1, "sourceCommit": source, "session": session, "owner": "studio",
            "phase": "initial", "requestGeneration": session,
            "capabilitySHA256": hash, "root": root,
            "hostIdentifier": "com.pulkit.edith.tests.worker-" + session,
            "home": root + "/studio-home",
            "dataDirectory": root + "/data/studio", "workerPath": worker,
            "rolePath": worker + "/Contents/Resources/Payload/studio/app.bundle", "role": "app",
            "version": "1.0.0", "hostABI": "edith-host-2", "packageSHA256": hash,
            "producer": peer(10, root + "/Producer/functional-producer"),
            "engine": peer(11, worker + "/Contents/MacOS/Edith"),
            "operations": ["studio.export"],
            "inputs": [
                [
                    "name": "project", "path": root + "/inputs/studio/project.openscreen",
                    "sha256": hash, "maximumBytes": 1024,
                ]
            ],
            "outputs": [
                [
                    "name": "movie", "path": root + "/outputs/studio/movie.mp4",
                    "parent": root + "/outputs/studio",
                ]
            ],
        ]
    }
    private func seal(_ object: [String: Any], _ key: Curve25519.Signing.PrivateKey) throws -> Data
    {
        let payload = try WorkerFixtureUIContract.canonicalJSON(object)
        return try WorkerFixtureUIContract.canonicalJSON([
            "schema": 1, "payload": String(decoding: payload, as: UTF8.self),
            "signature": try key.signature(for: payload).base64EncodedString(),
        ])
    }
    @Test func signedEngineScopeIsIndependentOfUIAndKeepsProductionAnchorNil() throws {
        let key = Curve25519.Signing.PrivateKey()
        let descriptor = try WorkerFixtureEngineContract.verify(
            seal(object(), key), issuerKey: key.publicKey.rawRepresentation)
        try descriptor.validate(
            trust: trust(key.publicKey.rawRepresentation), owner: "studio", uid: 501)
        #expect(descriptor.inputs.count == 1 && descriptor.outputs.count == 1)
        #expect(WorkerFixtureUITrustAnchor.admitted == nil)
    }
    @Test func signedEngineClaimsCannotEscapeOwnedInputsOutputsOrGeneration() throws {
        let key = Curve25519.Signing.PrivateKey()
        let original = object()
        for patch: [String: Any] in [
            ["sourceCommit": String(repeating: "c", count: 40)], ["session": "foreign"],
            ["requestGeneration": "foreign"], ["root": "/private/outside"],
            ["role": "privileged"],
            [
                "role": "helper",
                "rolePath": worker + "/Contents/Resources/Payload/studio/helper.bundle",
            ], ["operations": ["studio.export", "studio.export"]],
            [
                "inputs": [
                    [
                        "name": "project", "path": "/private/userdata/project", "sha256": hash,
                        "maximumBytes": 1024,
                    ]
                ]
            ],
            [
                "outputs": [
                    [
                        "name": "movie", "path": root + "/outputs/studio/../movie.mp4",
                        "parent": root + "/outputs/studio",
                    ]
                ]
            ],
            [
                "outputs": [
                    [
                        "name": "movie", "path": root + "/outputs/other/movie.mp4",
                        "parent": root + "/outputs/other",
                    ]
                ]
            ],
            ["workerPath": root + "/foreign" + String(worker.dropFirst(root.count))],
            ["issuerKey": "caller-chosen"],
        ] {
            var value = original; value.merge(patch) { _, new in new }
            #expect(throws: (any Error).self) {
                let descriptor = try WorkerFixtureEngineContract.verify(
                    seal(value, key), issuerKey: key.publicKey.rawRepresentation)
                try descriptor.validate(
                    trust: trust(key.publicKey.rawRepresentation), owner: "studio", uid: 501)
            }
        }
        #expect(throws: (any Error).self) {
            try WorkerFixtureEngineContract.verify(
                seal(original, Curve25519.Signing.PrivateKey()),
                issuerKey: key.publicKey.rawRepresentation)
        }
    }
    @Test func originalNotchHelperSettingsServiceCannotBecomeGenericEngineOrSubstituteRole() throws
    {
        let key = Curve25519.Signing.PrivateKey()
        let trusted = try trust(key.publicKey.rawRepresentation)
        var value = object()
        for field in ["owner", "home", "dataDirectory", "workerPath", "rolePath"] {
            value[field] = (value[field] as! String).replacingOccurrences(
                of: "studio", with: "notchShelf"
            )
            .replacingOccurrences(of: "app.bundle", with: "helper.bundle")
        }
        var engine = value["engine"] as! [String: Any]
        engine["executable"] = (engine["executable"] as! String).replacingOccurrences(
            of: "studio", with: "notchShelf")
        value["engine"] = engine
        value["role"] = "helper"
        value["operations"] = ["notch.settings.read", "notch.settings.write"]
        value["inputs"] = [[String: Any]](); value["outputs"] = [[String: Any]]()
        let descriptor = try WorkerFixtureEngineContract.verify(
            seal(value, key), issuerKey: key.publicKey.rawRepresentation)
        try descriptor.validate(
            trust: trusted, owner: "notchShelf", uid: 501, expectedRole: .helper)
        #expect(throws: (any Error).self) {
            try descriptor.validate(trust: trusted, owner: "notchShelf", uid: 501)
        }
        for patch: [String: Any] in [
            ["owner": "plugins"], ["role": "app"],
            ["operations": ["notch.settings.read"]],
            ["operations": ["notch.settings.read", "notch.settings.write", "notch.panel.render"]],
            ["operations": ["settings.read", "settings.write"]],
            [
                "rolePath": (value["rolePath"] as! String).replacingOccurrences(
                    of: "helper.bundle", with: "app.bundle")
            ],
            ["engine": object()["engine"]!], ["inputs": object()["inputs"]!],
            ["outputs": object()["outputs"]!],
        ] {
            var changed = value; changed.merge(patch) { _, new in new }
            #expect(throws: (any Error).self) {
                try WorkerFixtureEngineContract.verify(
                    seal(changed, key), issuerKey: key.publicKey.rawRepresentation
                )
                .validate(trust: trusted, owner: "notchShelf", uid: 501, expectedRole: .helper)
            }
        }
        let identifier = "com.pulkit.edith.extensions.notchShelf.helper"
        try descriptor.requireObservedRole(
            identifier: identifier, path: descriptor.rolePath,
            certificate: trusted.roleCertificateSHA256, expectedRole: .helper, trust: trusted)
        for identity in [
            (
                identifier.replacingOccurrences(of: "helper", with: "app"), descriptor.rolePath,
                trusted.roleCertificateSHA256
            ),
            (
                identifier,
                descriptor.rolePath.replacingOccurrences(of: "helper.bundle", with: "app.bundle"),
                trusted.roleCertificateSHA256
            ),
            (identifier, descriptor.rolePath, trusted.workerCertificateSHA256),
        ] {
            #expect(throws: (any Error).self) {
                try descriptor.requireObservedRole(
                    identifier: identity.0, path: identity.1, certificate: identity.2,
                    expectedRole: .helper, trust: trusted)
            }
        }
    }

    @Test func engineContextRefusesUIAndMalformedBooleanIntent() throws {
        let host = "com.pulkit.edith.tests.worker-" + session
        let id = host + ".extension.studio.worker"
        let environment = [
            "EDITH_APPLICATION_IDENTIFIER": host, "EDITH_EXTENSION_ID": "studio",
            "EDITH_SHARED_DEFAULTS_SUITE": id,
        ]
        let context: [String: Any] = [
            "operation": "start", "hostIdentifier": host, "extensionID": "studio",
            "defaultsSuite": id,
        ]
        try WorkerFixtureEngineContract.validateContext(
            context as NSDictionary, environment: environment, owner: "studio", workerIdentifier: id
        )
        for patch: [String: Any] in [
            ["remoteUI": true], ["uiOnly": true], ["remoteUI": 0], ["uiOnly": 0],
            ["engineClient": NSObject()], ["operation": "configureUI"], ["defaultsSuite": "live"],
        ] {
            var value = context; value.merge(patch) { _, new in new }
            #expect(throws: (any Error).self) {
                try WorkerFixtureEngineContract.validateContext(
                    value as NSDictionary, environment: environment, owner: "studio",
                    workerIdentifier: id)
            }
        }
    }
    @Test func decodedJSONAliasesAndNestedDuplicatesRejectWithoutCanonicalFormattingRequirement()
        throws
    {
        #expect(
            try WorkerFixtureJSON.object(Data(" { \"values\" : { \"key\" : 1 } } ".utf8)).count == 1
        )
        for text in [
            "{\"key\":1,\"\\u006bey\":2}", "{\"nested\":[{\"key\":1,\"key\":2}]}", "[]", "true",
            "{\"unclosed\":",
        ] {
            #expect(throws: (any Error).self) { try WorkerFixtureJSON.object(Data(text.utf8)) }
        }
        #expect(throws: (any Error).self) {
            try WorkerFixtureJSON.object(Data("{}".utf8), maximumBytes: 1)
        }
        let depth =
            "{\"nested\":" + String(repeating: "[", count: 64) + "0"
            + String(repeating: "]", count: 64) + "}"
        #expect(throws: (any Error).self) { try WorkerFixtureJSON.object(Data(depth.utf8)) }
    }
    @Test func requestGateBindsReceiptAndRejectsReplayForeignGenerationAndCapacity() throws {
        let gate = WorkerFixtureEngineRequestGate(
            operations: ["studio.export"], generation: session)
        let foreign = WorkerFixtureEngineRequestGate(
            operations: ["studio.export"], generation: UUID().uuidString.lowercased())
        let payload = Data("{}".utf8)
        let request = try gate.begin(token: UUID(), operation: "studio.export", payload: payload)
        #expect(request.payloadSHA256 == WorkerFixtureUIAdmission.digest(payload))
        #expect(throws: (any Error).self) { try foreign.complete(request) }
        try gate.complete(request)
        #expect(throws: (any Error).self) { try gate.complete(request) }
        #expect(throws: (any Error).self) {
            try gate.begin(token: request.token, operation: "studio.export", payload: payload)
        }
        #expect(throws: (any Error).self) {
            try gate.begin(token: UUID(), operation: "studio.other", payload: payload)
        }
        var pending: [WorkerFixtureEngineRequest] = []
        for _ in 0..<8 {
            pending.append(
                try gate.begin(token: UUID(), operation: "studio.export", payload: payload))
        }
        #expect(throws: (any Error).self) {
            try gate.begin(token: UUID(), operation: "studio.export", payload: payload)
        }
        pending.forEach { gate.cancel($0) }
        for _ in 9..<128 {
            let value = try gate.begin(token: UUID(), operation: "studio.export", payload: payload);
            gate.cancel(value)
        }
        #expect(throws: (any Error).self) {
            try gate.begin(token: UUID(), operation: "studio.export", payload: payload)
        }
    }
}
