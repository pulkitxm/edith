import CryptoKit
import Foundation
import Testing
@testable import WorkerFixtureSupport

@MainActor struct WorkerFixtureEngineContractTests {
    private let session = "12345678-1234-4123-8123-123456789abc"
    private let source = String(repeating: "a", count: 40)
    private let hash = String(repeating: "b", count: 64)
    private var root: String { "/private/synthetic/functional-fixture-" + session }
    private var identityRoot: String { root + "/Edith Tests/worker-" + session }
    private var worker: String {
        identityRoot
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
            producerExecutableSHA256: hash,
            rolePolicies: [
                try WorkerFixtureRolePolicy(
                    owner: "studio", primaryRole: .app, operations: ["studio.export"],
                    presentations: [
                        try WorkerFixturePresentationScope(location: "main", section: "studio")
                    ], inputs: [try WorkerFixtureInputScope(name: "project", maximumBytes: 1024)],
                    outputs: ["movie"], fileScopes: [], manifestSHA256: hash, caseSHA256: hash),
                try WorkerFixtureRolePolicy(
                    owner: "notchShelf", primaryRole: .helper,
                    operations: ["notch.settings.read", "notch.settings.write"],
                    presentations: [
                        try WorkerFixturePresentationScope(
                            location: "settings", section: "extension")
                    ], inputs: [], outputs: [], fileScopes: [], manifestSHA256: hash,
                    caseSHA256: hash),
            ])
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
            "dataDirectory": identityRoot + "/Data/studio", "workerPath": worker,
            "rolePath": worker + "/Contents/Resources/Payload/studio/app.bundle", "role": "app",
            "version": "1.0.0", "hostABI": "edith-host-2", "packageSHA256": hash,
            "producer": peer(10, root + "/Producer/functional-producer"),
            "engine": peer(11, root + "/Fixture.app/Contents/MacOS/Edith"),
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
            [
                "engine": [
                    "pid": 11, "birthSeconds": 1000, "birthMicroseconds": 11, "uid": 501,
                    "executable": worker + "/Contents/MacOS/Edith", "executableSHA256": hash,
                ]
            ], ["inputs": object()["inputs"]!],
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
            "EDITH_SHARED_DEFAULTS_SUITE": host + ".extensions.studio",
        ]
        let context: [String: Any] = [
            "operation": "start", "hostIdentifier": host, "extensionID": "studio",
            "defaultsSuite": host + ".extensions.studio",
        ]
        try WorkerFixtureEngineContract.validateContext(
            context as NSDictionary, environment: environment, owner: "studio", workerIdentifier: id
        )
        for patch: [String: Any] in [
            ["remoteUI": true], ["uiOnly": true], ["remoteUI": 0], ["uiOnly": 0],
            ["engineClient": NSObject()], ["operation": "configureUI"], ["defaultsSuite": "live"],
            ["defaultsSuite": id],
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
    @Test func platformFactoryRejectsWrongOwnerRoleAndUnadmittedRootBeforeConstruction() throws {
        let key = Curve25519.Signing.PrivateKey()
        let admitted = try trust(key.publicKey.rawRepresentation)
        var factoryCalls = 0
        for candidate in [
            (object(), "notchShelf", WorkerFixtureRole.app),
            (object(), "studio", WorkerFixtureRole.helper),
            (
                object().merging(["home": "/private/unadmitted/studio-home"]) { _, new in new },
                "studio", WorkerFixtureRole.app
            ),
            (
                object().merging(["dataDirectory": "/private/unadmitted/data/studio"]) { _, new in
                    new
                },
                "studio", WorkerFixtureRole.app
            ),
        ] {
            let descriptor = try WorkerFixtureEngineContract.verify(
                seal(candidate.0, key), issuerKey: key.publicKey.rawRepresentation)
            let scope = WorkerFixtureEngineFactoryScope(
                descriptor: descriptor, trust: admitted, owner: candidate.1, role: candidate.2,
                uid: 501)
            #expect(throws: (any Error).self) {
                try scope.perform(requireCurrent: {}) { factoryCalls += 1 }
            }
        }
        #expect(factoryCalls == 0)
    }

    @Test func platformFactoryRevalidatesAuthorityBeforeAndAfterConstruction() throws {
        let key = Curve25519.Signing.PrivateKey()
        let descriptor = try WorkerFixtureEngineContract.verify(
            seal(object(), key), issuerKey: key.publicKey.rawRepresentation)
        let scope = WorkerFixtureEngineFactoryScope(
            descriptor: descriptor, trust: try trust(key.publicKey.rawRepresentation),
            owner: "studio", role: .app, uid: 501)
        var current = false
        var factoryCalls = 0
        var checks = 0
        let validate = {
            checks += 1
            guard current else { throw WorkerFixtureError.invalid }
        }
        #expect(throws: (any Error).self) {
            try scope.perform(requireCurrent: validate) { factoryCalls += 1 }
        }
        #expect(factoryCalls == 0 && checks == 1)
        current = true
        #expect(throws: (any Error).self) {
            try scope.perform(requireCurrent: validate) {
                factoryCalls += 1
                current = false
                return "discarded"
            }
        }
        #expect(factoryCalls == 1 && checks == 3)
        current = true
        let result = try scope.perform(requireCurrent: validate) {
            factoryCalls += 1
            return "verified"
        }
        #expect(result == "verified" && factoryCalls == 2 && checks == 5)
        #expect(throws: (any Error).self) {
            try scope.perform(requireCurrent: validate) { throw WorkerFixtureError.invalid }
        }
        #expect(checks == 6)
    }

    @Test func unsignedLegacyAdmissionCannotAcceptFunctionalIntent() throws {
        for intent in [
            (NSDictionary(), ["EDITH_FUNCTIONAL_FIXTURE": "1"]),
            (NSDictionary(), ["EDITH_FUNCTIONAL_FIXTURE": "0"]),
            (["hostedFunctionalFixture": [:]] as NSDictionary, [String: String]()),
        ] {
            #expect(throws: (any Error).self) {
                try WorkerFixtureAdmission.admit(
                    extensionID: "studio", context: intent.0,
                    environment: intent.1,
                    hostIdentifier: "com.pulkit.edith", hostBundle: URL(fileURLWithPath: "/unused"),
                    roleDirectory: URL(fileURLWithPath: "/unused"), roleIdentifier: nil,
                    version: nil, hostABI: nil)
            }
        }
    }

    private func outputPolicy(_ scopes: [WorkerFixtureFileScope]) throws -> WorkerFixtureRolePolicy
    {
        try WorkerFixtureRolePolicy(
            owner: "blitztree", primaryRole: .app, operations: ["blitztree.probe"],
            presentations: [
                try WorkerFixturePresentationScope(location: "main", section: "blitztree")
            ],
            inputs: [], outputs: ["victim"], fileScopes: scopes, manifestSHA256: hash,
            caseSHA256: hash)
    }
    private func mutableOutput(
        root: WorkerFixtureFileRoot = .ownerOutputs,
        initial: WorkerFixtureFilePresence = .present,
        states: [WorkerFixtureFilePresence] = [.present, .absent]
    ) throws -> WorkerFixtureFileScope {
        try WorkerFixtureFileScope(
            name: "victim", kind: .file, purpose: .mutableState, root: root,
            components: [.phase, .literal("victim.txt")], maximumBytes: 16,
            maximumEntries: 1, initialState: initial, allowedStates: states,
            immutableFiles: [], mutableFiles: [])
    }
    private var victimOutput: WorkerFixtureEngineOutput {
        WorkerFixtureEngineOutput(
            name: "victim", path: root + "/outputs/blitztree/initial/victim.txt",
            parent: root + "/outputs/blitztree/initial")
    }
    @Test func preexistingMutableOutputRequiresExactCompiledStateAndByteBounds() throws {
        let scope = try WorkerFixtureEngineOutputScope(
            output: victimOutput, policy: outputPolicy([mutableOutput()]),
            root: root, session: session, phase: "initial")
        try scope.validate(present: true, bytes: 16, initial: true)
        try scope.validate(present: true, bytes: 0, initial: false)
        try scope.validate(present: false, bytes: 0, initial: false)
        #expect(throws: WorkerFixtureError.self) {
            try scope.validate(present: false, bytes: 0, initial: true)
        }
        #expect(throws: WorkerFixtureError.self) {
            try scope.validate(present: true, bytes: 17, initial: false)
        }
        #expect(throws: WorkerFixtureError.self) {
            try scope.validate(present: true, bytes: -1, initial: false)
        }
        #expect(throws: WorkerFixtureError.self) {
            try scope.validate(present: false, bytes: 1, initial: false)
        }
        let retained = try WorkerFixtureEngineOutputScope(
            output: victimOutput,
            policy: outputPolicy([mutableOutput(states: [.present])]),
            root: root, session: session, phase: "initial")
        #expect(throws: WorkerFixtureError.self) {
            try retained.validate(present: false, bytes: 0, initial: false)
        }
    }
    @Test func ordinaryOutputStillRequiresInitialAbsenceWithoutMutableAuthority() throws {
        let scope = try WorkerFixtureEngineOutputScope(
            output: victimOutput, policy: outputPolicy([]),
            root: root, session: session, phase: "initial")
        try scope.validate(present: false, bytes: 0, initial: true)
        #expect(throws: WorkerFixtureError.self) {
            try scope.validate(present: true, bytes: 1, initial: true)
        }
        try scope.validate(present: true, bytes: 1, initial: false)
        let named = try WorkerFixtureFileScope(
            name: "victim", kind: .file, purpose: .initiallyAbsentOutput,
            root: .ownerOutputs, components: [.phase, .literal("victim.txt")],
            maximumBytes: 16, maximumEntries: 1, initialState: .absent,
            allowedStates: [.absent, .present], immutableFiles: [], mutableFiles: [])
        let namedOutput = try WorkerFixtureEngineOutputScope(
            output: victimOutput, policy: outputPolicy([named]),
            root: root, session: session, phase: "initial")
        try namedOutput.validate(present: false, bytes: 0, initial: true)
        try namedOutput.validate(present: true, bytes: 16, initial: false)
        #expect(throws: WorkerFixtureError.self) {
            try namedOutput.validate(present: true, bytes: 17, initial: false)
        }
        #expect(throws: WorkerFixtureError.self) {
            try namedOutput.validate(present: true, bytes: 1, initial: true)
        }
        let absent = try WorkerFixtureEngineOutputScope(
            output: victimOutput,
            policy: outputPolicy([mutableOutput(initial: .absent)]),
            root: root, session: session, phase: "initial")
        #expect(throws: WorkerFixtureError.self) {
            try absent.validate(present: true, bytes: 1, initial: true)
        }
    }
    @Test func mutableOutputAuthorityRejectsWrongOwnerNameRootPhaseAndDerivedLeaf() throws {
        let policy = try outputPolicy([mutableOutput()])
        for output in [
            WorkerFixtureEngineOutput(
                name: "other", path: victimOutput.path, parent: victimOutput.parent),
            WorkerFixtureEngineOutput(
                name: "victim", path: root + "/outputs/studio/initial/victim.txt",
                parent: root + "/outputs/studio/initial"),
            WorkerFixtureEngineOutput(
                name: "victim", path: root + "/outputs/blitztree/initial/arbitrary.txt",
                parent: victimOutput.parent),
            WorkerFixtureEngineOutput(
                name: "victim", path: root + "/outputs/blitztree/initial/../victim.txt",
                parent: root + "/outputs/blitztree/initial/.."),
        ] {
            #expect(throws: WorkerFixtureError.self) {
                try WorkerFixtureEngineOutputScope(
                    output: output, policy: policy, root: root, session: session, phase: "initial")
            }
        }
        for phase in ["updated", "reinstalled", "unchecked"] {
            #expect(throws: WorkerFixtureError.self) {
                try WorkerFixtureEngineOutputScope(
                    output: victimOutput, policy: policy, root: root, session: session, phase: phase
                )
            }
        }
        #expect(throws: WorkerFixtureError.self) {
            try WorkerFixtureEngineOutputScope(
                output: victimOutput, policy: outputPolicy([mutableOutput(root: .ownerHome)]),
                root: root, session: session, phase: "initial")
        }
        #expect(throws: WorkerFixtureError.self) {
            try WorkerFixtureEngineOutputScope(
                output: victimOutput, policy: policy, root: "/private/foreign",
                session: session, phase: "initial")
        }
    }

}
