import CoreFoundation
import CryptoKit
import Foundation

public struct WorkerFixtureEngineInput: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let sha256: String
    public let maximumBytes: Int

    @MainActor func read(_ file: WorkerFixtureUIOpenedPath) throws -> Data {
        guard file.url.path == path, maximumBytes > 0, maximumBytes <= 268_435_456,
            file.original.st_size > 0, file.original.st_size <= maximumBytes
        else { throw WorkerFixtureError.invalid }
        let data = try file.read()
        guard data.count <= maximumBytes, WorkerFixtureUIAdmission.digest(data) == sha256
        else { throw WorkerFixtureError.invalid }
        return data
    }
}

public struct WorkerFixtureEngineOutput: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let parent: String
}

public struct WorkerFixtureEngineContract: Codable, Equatable, Sendable {
    public let schema: Int
    public let sourceCommit: String
    public let session: String
    public let owner: String
    public let phase: String
    public let requestGeneration: String
    public let capabilitySHA256: String
    public let root: String
    public let hostIdentifier: String
    public let home: String
    public let dataDirectory: String
    public let workerPath: String
    public let rolePath: String
    public let role: String
    public let version: String
    public let hostABI: String
    public let packageSHA256: String
    public let producer: WorkerFixtureUIProcess
    public let engine: WorkerFixtureUIProcess
    public let operations: [String]
    public let inputs: [WorkerFixtureEngineInput]
    public let outputs: [WorkerFixtureEngineOutput]

    public static func verify(_ bytes: Data, issuerKey: Data) throws -> Self {
        let envelope = try WorkerFixtureJSON.object(bytes, maximumBytes: 131_072)
        guard issuerKey.count == 32, Set(envelope.keys) == ["schema", "payload", "signature"],
            let schema = envelope["schema"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema == 1,
            let payload = envelope["payload"] as? String, !payload.isEmpty,
            payload.utf8.count <= 65_536,
            let encoded = envelope["signature"] as? String,
            let signature = Data(base64Encoded: encoded), signature.count == 64,
            signature.base64EncodedString() == encoded,
            try WorkerFixtureUIContract.canonicalJSON(envelope) == bytes
        else { throw WorkerFixtureError.invalid }
        let data = Data(payload.utf8)
        let object = try WorkerFixtureJSON.object(data, maximumBytes: 65_536)
        guard
            Set(object.keys) == [
                "schema", "sourceCommit", "session", "owner", "phase", "requestGeneration",
                "capabilitySHA256", "root", "hostIdentifier", "home", "dataDirectory", "workerPath",
                "rolePath", "role", "version", "hostABI", "packageSHA256", "producer", "engine",
                "operations", "inputs", "outputs",
            ], let schema = object["schema"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema == 1,
            ["producer", "engine"].allSatisfy({ name in
                guard let process = object[name] as? [String: Any] else { return false }
                return Set(process.keys) == [
                    "pid", "birthSeconds", "birthMicroseconds", "uid", "executable",
                    "executableSHA256",
                ]
            }), let inputs = object["inputs"] as? [[String: Any]],
            inputs.allSatisfy({ Set($0.keys) == ["name", "path", "sha256", "maximumBytes"] }),
            let outputs = object["outputs"] as? [[String: Any]],
            outputs.allSatisfy({ Set($0.keys) == ["name", "path", "parent"] }),
            try WorkerFixtureUIContract.canonicalJSON(object) == data,
            try Curve25519.Signing.PublicKey(rawRepresentation: issuerKey)
                .isValidSignature(signature, for: data)
        else { throw WorkerFixtureError.invalid }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public static func validateContext(
        _ context: NSDictionary, environment: [String: String], owner: String,
        workerIdentifier: String
    ) throws {
        func absentOrFalse(_ name: String) -> Bool {
            guard let value = context[name] else { return true }
            guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID()
            else { return false }
            return !value.boolValue
        }
        guard WorkerFixtureUIContract.owners.contains(owner),
            context["operation"] as? String == "start",
            absentOrFalse("remoteUI"), absentOrFalse("uiOnly"), context["engineClient"] == nil,
            let host = context["hostIdentifier"] as? String,
            host.hasPrefix("com.pulkit.edith.tests.worker-"),
            WorkerFixtureUIContract.uuid(
                String(host.dropFirst("com.pulkit.edith.tests.worker-".count))),
            workerIdentifier == host + ".extension." + owner + ".worker",
            context["extensionID"] as? String == owner,
            context["defaultsSuite"] as? String == host + ".extensions." + owner,
            environment["EDITH_APPLICATION_IDENTIFIER"] == host,
            environment["EDITH_EXTENSION_ID"] == owner,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == host + ".extensions." + owner
        else { throw WorkerFixtureError.invalid }
    }

    public func validate(
        trust: WorkerFixtureUITrust, owner expectedOwner: String, uid: UInt32,
        expectedRole: WorkerFixtureRole = .app
    ) throws {
        let policy = try trust.rolePolicy(owner: expectedOwner)
        guard policy.primaryRole == expectedRole else { throw WorkerFixtureError.invalid }
        try policy.validateEngine(self)
        try validateBounds(trust: trust, owner: expectedOwner, uid: uid, expectedRole: expectedRole)
    }

    public func validate(
        trust: WorkerFixtureBootstrapTrust, owner expectedOwner: String, uid: UInt32,
        expectedRole: WorkerFixtureRole = .app
    ) throws {
        let policy = try trust.rolePolicy(owner: expectedOwner)
        guard policy.primaryRole == expectedRole else { throw WorkerFixtureError.invalid }
        try policy.validateEngine(self)
        try validateBounds(trust: trust, owner: expectedOwner, uid: uid, expectedRole: expectedRole)
    }

    func validateBounds<T: WorkerFixtureTrustBounds>(
        trust: T, owner expectedOwner: String, uid: UInt32, expectedRole: WorkerFixtureRole
    ) throws {
        try trust.validate()
        guard schema == 1, owner == expectedOwner, WorkerFixtureUIContract.owners.contains(owner),
            sourceCommit == trust.sourceCommit, session == trust.session, root == trust.root,
            hostIdentifier == trust.hostIdentifier,
            ["initial", "updated", "reinstalled"].contains(phase),
            WorkerFixtureUIContract.uuid(requestGeneration),
            WorkerFixtureUIContract.hex(capabilitySHA256, count: 64),
            home == root + "/" + owner + "-home",
            dataDirectory == WorkerFixtureUIContract.identityRoot(root: root, session: session)
                + "/Data/" + owner,
            WorkerFixtureUIContract.version(version), hostABI == "edith-host-2",
            WorkerFixtureUIContract.hex(packageSHA256, count: 64),
            WorkerFixtureUIContract.canonical(workerPath),
            workerPath == WorkerFixtureUIContract.identityRoot(root: root, session: session)
                + "/Extensions/" + owner + "/edith-host-2/arm64/" + version + "/"
                + owner
                + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex",
            role == expectedRole.rawValue,
            rolePath == workerPath + "/Contents/Resources/Payload/" + owner + "/" + role
                + ".bundle",
            producer.executable == trust.producerExecutable,
            producer.executableSHA256 == trust.producerExecutableSHA256,
            producer.pid != engine.pid,
            engine.executable == root + "/Fixture.app/Contents/MacOS/Edith",
            !operations.isEmpty, operations.count <= 16, Set(operations).count == operations.count,
            operations.allSatisfy(Self.operation), inputs.count <= 64, outputs.count <= 64,
            Set(inputs.map(\.name) + outputs.map(\.name)).count == inputs.count + outputs.count,
            Set(inputs.map(\.path) + outputs.map(\.path)).count == inputs.count + outputs.count,
            inputs.allSatisfy({ input in
                Self.name(input.name) && WorkerFixtureUIContract.canonical(input.path)
                    && input.path.hasPrefix(root + "/inputs/" + owner + "/")
                    && WorkerFixtureUIContract.hex(input.sha256, count: 64)
                    && input.maximumBytes > 0 && input.maximumBytes <= 268_435_456
            }),
            outputs.allSatisfy({ output in
                Self.name(output.name) && WorkerFixtureUIContract.canonical(output.path)
                    && WorkerFixtureUIContract.canonical(output.parent)
                    && (output.parent == root + "/outputs/" + owner
                        || output.parent.hasPrefix(root + "/outputs/" + owner + "/"))
                    && URL(fileURLWithPath: output.path).deletingLastPathComponent().path
                        == output.parent
            })
        else { throw WorkerFixtureError.invalid }
        try producer.validate(uid: uid)
        try engine.validate(uid: uid)
    }

    func requireObservedRole(
        identifier: String, path: String, certificate: Data, expectedRole: WorkerFixtureRole,
        trust: WorkerFixtureUITrust
    ) throws {
        guard role == expectedRole.rawValue, path == rolePath,
            identifier == "com.pulkit.edith.extensions." + owner + "." + expectedRole.rawValue,
            certificate == trust.roleCertificateSHA256
        else { throw WorkerFixtureError.invalid }
    }

    private static func name(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 128
            && text.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
    }
    private static func operation(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 256
            && text.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
    }
}
