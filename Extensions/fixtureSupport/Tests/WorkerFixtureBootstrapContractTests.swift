import CryptoKit
import Darwin
import Foundation
import Testing
@testable import WorkerFixtureSupport

@MainActor struct WorkerFixtureBootstrapContractTests {
    private let session = "12345678-1234-4123-8123-123456789abc"
    private let source = String(repeating: "a", count: 40)
    private let hash = String(repeating: "b", count: 64)
    private var root: String { "/private/synthetic/functional-fixture-" + session }
    private var host: String { "com.pulkit.edith.tests.worker-" + session }
    private var worker: String {
        root
            + "/Extensions/plugins/edith-host-2/arm64/1.0.0/plugins/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex"
    }

    private func trust(_ issuer: Data, sourceCommit: String? = nil) throws
        -> WorkerFixtureBootstrapTrust
    {
        try WorkerFixtureBootstrapTrust(
            sourceCommit: sourceCommit ?? source, session: session, root: root, issuerKey: issuer,
            hostRequirement: "identifier synthetic.fixture",
            hostCertificateSHA256: Data(repeating: 1, count: 32),
            workerCertificateSHA256: Data(repeating: 2, count: 32),
            roleCertificateSHA256: Data(repeating: 3, count: 32),
            producerExecutable: root + "/Producer/functional-producer",
            producerExecutableSHA256: hash)
    }
    private func object(_ ui: Bool) -> [String: Any] {
        func peer(_ pid: Int, _ path: String) -> [String: Any] {
            [
                "pid": pid, "birthSeconds": 1000, "birthMicroseconds": pid, "uid": 501,
                "executable": path, "executableSHA256": hash,
            ]
        }
        var value: [String: Any] = [
            "schema": 1, "sourceCommit": source, "session": session, "owner": "plugins",
            "phase": "initial",
            "capabilitySHA256": hash, "root": root, "hostIdentifier": host,
            "home": root + "/plugins-home",
            "dataDirectory": root + "/data/plugins", "workerPath": worker,
            "rolePath": worker + "/Contents/Resources/Payload/plugins/app.bundle",
            "version": "1.0.0",
            "hostABI": "edith-host-2", "packageSHA256": hash,
            "producer": peer(10, root + "/Producer/functional-producer"),
            "engine": peer(11, worker + "/Contents/MacOS/Edith"),
        ]
        if ui {
            value["presentationID"] = session; value["location"] = "main";
            value["section"] = "plugins"
            value["ui"] = peer(12, worker + "/Contents/MacOS/Edith")
        } else {
            value["role"] = "app"; value["requestGeneration"] = session
            value["operations"] = ["plugins.agents.read", "plugins.agents.write"]
            value["inputs"] = [[String: Any]](); value["outputs"] = [[String: Any]]()
        }
        return value
    }
    private func seal(_ value: [String: Any], _ key: Curve25519.Signing.PrivateKey) throws -> Data {
        let payload = try WorkerFixtureUIContract.canonicalJSON(value)
        return try WorkerFixtureUIContract.canonicalJSON([
            "schema": 1, "payload": String(decoding: payload, as: UTF8.self),
            "signature": try key.signature(for: payload).base64EncodedString(),
        ])
    }

    @Test func independentBootstrapTrustAuthenticatesBeforeRoleConstructionWithoutSelfDigest()
        throws
    {
        let key = Curve25519.Signing.PrivateKey()
        let trusted = try trust(key.publicKey.rawRepresentation)
        for ui in [false, true] {
            let contract = try WorkerFixtureBootstrapContract.verify(
                seal(object(ui), key), purpose: ui ? .ui : .engine, trust: trusted,
                owner: "plugins", expectedRole: .app, uid: 501)
            #expect(contract.contextMarker["sourceCommit"] == source)
            #expect(contract.contextMarker["session"] == session)
            try contract.validateMarker(contract.contextMarker as NSDictionary)
            for field in contract.contextMarker.keys {
                var marker = contract.contextMarker; marker[field] = "foreign"
                #expect(throws: (any Error).self) {
                    try contract.validateMarker(marker as NSDictionary)
                }
            }
        }
        #expect(WorkerFixtureBootstrapTrustAnchor.admitted == nil)
        #expect(WorkerFixtureUITrustAnchor.admitted == nil)
    }

    @Test func signedDescriptorCannotChooseIssuerSourceScopeRoleOrProcessIdentity() throws {
        let key = Curve25519.Signing.PrivateKey()
        for ui in [false, true] {
            let original = object(ui)
            for patch: [String: Any] in [
                ["issuerKey": key.publicKey.rawRepresentation.base64EncodedString()],
                ["hostCertificateSHA256": hash],
                ["sourceCommit": String(repeating: "c", count: 40)],
                ["session": UUID().uuidString.lowercased()], ["root": "/private/outside"],
                ["hostIdentifier": "com.pulkit.edith"], ["home": root + "/outside-home"],
                ["dataDirectory": root + "/data/other"],
                ["rolePath": worker + "/Contents/Resources/Payload/plugins/helper.bundle"],
                ["schema": true], ["workerPath": "/private/outside/" + worker],
            ] {
                var changed = original; changed.merge(patch) { _, new in new }
                #expect(throws: (any Error).self) {
                    try WorkerFixtureBootstrapContract.verify(
                        seal(changed, key), purpose: ui ? .ui : .engine,
                        trust: trust(key.publicKey.rawRepresentation), owner: "plugins",
                        expectedRole: .app, uid: 501)
                }
            }
            for peerName in ui ? ["producer", "engine", "ui"] : ["producer", "engine"] {
                for patch: [String: Any] in [
                    ["uid": 502], ["birthSeconds": 0], ["pid": 1], ["executable": "/usr/bin/true"],
                ] {
                    var changed = original; var peer = changed[peerName] as! [String: Any]
                    peer.merge(patch) { _, new in new }; changed[peerName] = peer
                    #expect(throws: (any Error).self) {
                        try WorkerFixtureBootstrapContract.verify(
                            seal(changed, key), purpose: ui ? .ui : .engine,
                            trust: trust(key.publicKey.rawRepresentation), owner: "plugins",
                            expectedRole: .app, uid: 501)
                    }
                }
            }
            let bytes = try seal(original, key)
            #expect(throws: (any Error).self) {
                try WorkerFixtureBootstrapContract.verify(
                    bytes, purpose: ui ? .ui : .engine,
                    trust: trust(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation),
                    owner: "plugins", expectedRole: .app, uid: 501)
            }
            #expect(throws: (any Error).self) {
                try WorkerFixtureBootstrapContract.verify(
                    bytes, purpose: ui ? .ui : .engine,
                    trust: trust(
                        key.publicKey.rawRepresentation,
                        sourceCommit: String(repeating: "c", count: 40)), owner: "plugins",
                    expectedRole: .app, uid: 501)
            }
            #expect(throws: (any Error).self) {
                try WorkerFixtureBootstrapContract.verify(
                    bytes, purpose: ui ? .ui : .engine,
                    trust: trust(key.publicKey.rawRepresentation), owner: "plugins",
                    expectedRole: .helper, uid: 501)
            }
        }
    }

    @Test func bootstrapUIRequiresOriginalPresentationScopeButNoConstructedEngineClient() throws {
        let trusted = try trust(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let identifier = host + ".extension.plugins.worker"
        let context: [String: Any] = [
            "operation": "configureUI", "remoteUI": true, "uiOnly": false, "hostIdentifier": host,
            "extensionID": "plugins", "defaultsSuite": identifier,
            "dataDirectory": root + "/data/plugins",
            "location": "main", "section": "plugins", "presentationID": session,
        ]
        let environment = [
            "HOME": root + "/plugins-home", "CFFIXED_USER_HOME": root + "/plugins-home",
            "EDITH_EXTENSION_FIXTURE_HOME": root + "/plugins-home",
            "EDITH_EXTENSION_DATA_ROOT": root + "/data/plugins",
            "EDITH_APPLICATION_IDENTIFIER": host, "EDITH_EXTENSION_ID": "plugins",
            "EDITH_SHARED_DEFAULTS_SUITE": identifier,
        ]
        try WorkerFixtureBootstrapContract.validateContext(
            context as NSDictionary, environment: environment, purpose: .ui, trust: trusted,
            owner: "plugins", expectedRole: .app, workerIdentifier: identifier)
        for patch: [String: Any] in [
            ["operation": "start"], ["remoteUI": false], ["remoteUI": 1], ["uiOnly": true],
            ["presentationID": "foreign"], ["defaultsSuite": "com.pulkit.edith"],
            ["dataDirectory": "/private/outside"], ["section": "outside"],
        ] {
            var changed = context; changed.merge(patch) { _, new in new }
            #expect(throws: (any Error).self) {
                try WorkerFixtureBootstrapContract.validateContext(
                    changed as NSDictionary, environment: environment, purpose: .ui, trust: trusted,
                    owner: "plugins", expectedRole: .app, workerIdentifier: identifier)
            }
        }
        for field in [
            "HOME", "CFFIXED_USER_HOME", "EDITH_EXTENSION_FIXTURE_HOME",
            "EDITH_EXTENSION_DATA_ROOT", "EDITH_SHARED_DEFAULTS_SUITE",
        ] {
            var changed = environment; changed[field] = "/private/outside"
            #expect(throws: (any Error).self) {
                try WorkerFixtureBootstrapContract.validateContext(
                    context as NSDictionary, environment: changed, purpose: .ui, trust: trusted,
                    owner: "plugins", expectedRole: .app, workerIdentifier: identifier)
            }
        }
    }

    @Test func originalNotchHelperUIBindsSignedSettingsEngineCapabilityAndOriginalBridge() throws {
        let key = Curve25519.Signing.PrivateKey()
        let trusted = try trust(key.publicKey.rawRepresentation)
        func notch(_ ui: Bool) -> [String: Any] {
            var value = object(ui)
            for field in ["owner", "home", "dataDirectory", "workerPath", "rolePath"] {
                value[field] = (value[field] as! String).replacingOccurrences(
                    of: "plugins", with: "notchShelf"
                )
                .replacingOccurrences(of: "app.bundle", with: "helper.bundle")
            }
            for field in ui ? ["engine", "ui"] : ["engine"] {
                var peer = value[field] as! [String: Any]
                peer["executable"] = (peer["executable"] as! String).replacingOccurrences(
                    of: "plugins", with: "notchShelf")
                value[field] = peer
            }
            if ui {
                value["location"] = "settings"; value["section"] = "notchShelf"
            } else {
                value["role"] = "helper";
                value["operations"] = ["notch.settings.read", "notch.settings.write"]
            }
            return value
        }
        let uiObject = notch(true); let engineObject = notch(false)
        let uiBytes = try seal(uiObject, key); let engineBytes = try seal(engineObject, key)
        let contract = try WorkerFixtureBootstrapContract.verify(
            uiBytes, purpose: .ui, trust: trusted, owner: "notchShelf", expectedRole: .helper,
            uid: 501, engineDescriptorData: engineBytes)
        let service = try WorkerFixtureEngineContract.verify(
            engineBytes, issuerKey: trusted.issuerKey)
        try service.validate(trust: trusted, owner: "notchShelf", uid: 501, expectedRole: .helper)
        #expect(contract.contextMarker["capabilitySHA256"] == service.capabilitySHA256)
        #expect(throws: (any Error).self) {
            try WorkerFixtureBootstrapContract.verify(
                uiBytes, purpose: .ui, trust: trusted, owner: "notchShelf", expectedRole: .helper,
                uid: 501)
        }
        for patch: [String: Any] in [
            ["owner": "keepAwake"],
            ["operations": ["notch.settings.read", "notch.settings.write", "notch.panel.render"]],
            ["capabilitySHA256": String(repeating: "c", count: 64)], ["phase": "updated"],
            ["role": "app"],
            [
                "rolePath": (engineObject["rolePath"] as! String).replacingOccurrences(
                    of: "helper.bundle", with: "app.bundle")
            ],
            ["workerPath": worker],
            [
                "inputs": [
                    [
                        "name": "outside", "path": "/private/outside", "sha256": hash,
                        "maximumBytes": 1,
                    ]
                ]
            ],
        ] {
            var changed = engineObject; changed.merge(patch) { _, new in new }
            #expect(throws: (any Error).self) {
                try WorkerFixtureBootstrapContract.verify(
                    uiBytes, purpose: .ui, trust: trusted, owner: "notchShelf",
                    expectedRole: .helper, uid: 501, engineDescriptorData: seal(changed, key))
            }
        }
        for patch: [String: Any] in [
            ["pid": 14], ["birthSeconds": 2000], ["birthMicroseconds": 12],
            ["executableSHA256": String(repeating: "c", count: 64)],
            ["executable": worker + "/Contents/MacOS/Edith"],
        ] {
            var changed = engineObject; var peer = changed["engine"] as! [String: Any]
            peer.merge(patch) { _, new in new }; changed["engine"] = peer
            #expect(throws: (any Error).self) {
                try WorkerFixtureBootstrapContract.verify(
                    uiBytes, purpose: .ui, trust: trusted, owner: "notchShelf",
                    expectedRole: .helper, uid: 501, engineDescriptorData: seal(changed, key))
            }
        }
        for patch: [String: Any] in [
            ["location": "main"], ["section": "panel.1"], ["presentationID": "foreign"],
            ["rolePath": worker + "/Contents/Resources/Payload/plugins/app.bundle"],
        ] {
            var changed = uiObject; changed.merge(patch) { _, new in new }
            #expect(throws: (any Error).self) {
                try WorkerFixtureBootstrapContract.verify(
                    seal(changed, key), purpose: .ui, trust: trusted, owner: "notchShelf",
                    expectedRole: .helper, uid: 501, engineDescriptorData: engineBytes)
            }
        }
        let identifier = host + ".extension.notchShelf.worker"
        let context: [String: Any] = [
            "operation": "configureUI", "remoteUI": true, "uiOnly": false,
            "hostIdentifier": host, "extensionID": "notchShelf", "defaultsSuite": identifier,
            "dataDirectory": root + "/data/notchShelf", "location": "settings",
            "section": "notchShelf",
            "presentationID": session, "engineClient": BootstrapInertClient(),
        ]
        let environment = [
            "HOME": root + "/notchShelf-home", "CFFIXED_USER_HOME": root + "/notchShelf-home",
            "EDITH_EXTENSION_FIXTURE_HOME": root + "/notchShelf-home",
            "EDITH_EXTENSION_DATA_ROOT": root + "/data/notchShelf",
            "EDITH_APPLICATION_IDENTIFIER": host, "EDITH_EXTENSION_ID": "notchShelf",
            "EDITH_SHARED_DEFAULTS_SUITE": identifier,
        ]
        try WorkerFixtureBootstrapContract.validateContext(
            context as NSDictionary, environment: environment, purpose: .ui, trust: trusted,
            owner: "notchShelf", expectedRole: .helper, workerIdentifier: identifier,
            settingsService: service)
        #expect(throws: (any Error).self) {
            try WorkerFixtureBootstrapContract.validateContext(
                context as NSDictionary, environment: environment, purpose: .ui, trust: trusted,
                owner: "notchShelf", expectedRole: .helper, workerIdentifier: identifier)
        }
        var missingBridge = context; missingBridge["engineClient"] = nil
        #expect(throws: (any Error).self) {
            try WorkerFixtureBootstrapContract.validateContext(
                missingBridge as NSDictionary, environment: environment, purpose: .ui,
                trust: trusted, owner: "notchShelf", expectedRole: .helper,
                workerIdentifier: identifier, settingsService: service)
        }
        for patch: [String: Any] in [
            ["engineClient": NSObject()], ["uiOnly": true], ["uiOnly": 0], ["location": "notch"],
            ["section": "panel.1"],
            ["extensionID": "keepAwake"], ["target": "panel"], ["operation": "start"],
        ] {
            var changed = context; changed.merge(patch) { _, new in new }
            #expect(throws: (any Error).self) {
                try WorkerFixtureBootstrapContract.validateContext(
                    changed as NSDictionary, environment: environment, purpose: .ui, trust: trusted,
                    owner: "notchShelf", expectedRole: .helper, workerIdentifier: identifier,
                    settingsService: service)
            }
        }
    }

    @Test func heldInputReaderRejectsRepointedMutatedUnboundedAndForeignSignedInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("agents.json")
        let data = Data("{\"agentIDs\":[\"synthetic-agent\"]}".utf8)
        try data.write(to: path);
        guard chmod(path.path, 0o600) == 0 else { throw WorkerFixtureError.invalid }
        let input = WorkerFixtureEngineInput(
            name: "agents", path: path.path, sha256: WorkerFixtureUIAdmission.digest(data),
            maximumBytes: 1024)
        let opened = try WorkerFixtureUIOpenedPath(
            path, directory: false, mode: 0o600, maximum: input.maximumBytes)
        #expect(try input.read(opened) == data)
        for changed in [
            WorkerFixtureEngineInput(
                name: "agents", path: path.path, sha256: String(repeating: "0", count: 64),
                maximumBytes: 1024),
            WorkerFixtureEngineInput(
                name: "agents", path: path.path, sha256: input.sha256, maximumBytes: 1),
            WorkerFixtureEngineInput(
                name: "agents", path: directory.appendingPathComponent("other.json").path,
                sha256: input.sha256, maximumBytes: 1024),
        ] { #expect(throws: (any Error).self) { try changed.read(opened) } }
        let held = directory.appendingPathComponent("held.json")
        try FileManager.default.moveItem(at: path, to: held)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: held)
        #expect(throws: (any Error).self) { try input.read(opened) }
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: held, to: path)
        let fresh = try WorkerFixtureUIOpenedPath(
            path, directory: false, mode: 0o600, maximum: input.maximumBytes)
        let handle = try FileHandle(forWritingTo: path);
        try handle.write(contentsOf: Data(" ".utf8)); try handle.close()
        #expect(throws: (any Error).self) { try input.read(fresh) }
    }
}

private final class BootstrapInertClient: NSObject {
    @objc(invoke:completion:)
    func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        completion(nil, "inert")
    }
    @objc func cancel(_ token: String) {}
}
