import CoreFoundation
import CryptoKit
import Foundation

public struct WorkerFixtureUIProcess: Codable, Equatable, Sendable {
    public let pid: Int32
    public let birthSeconds: UInt64
    public let birthMicroseconds: UInt32
    public let uid: UInt32
    public let executable: String
    public let executableSHA256: String

    func validate(uid: UInt32) throws {
        guard pid > 1, birthSeconds > 0, birthMicroseconds < 1_000_000, self.uid == uid,
            WorkerFixtureUIContract.canonical(executable),
            WorkerFixtureUIContract.hex(executableSHA256, count: 64)
        else { throw WorkerFixtureError.invalid }
    }
}

public struct WorkerFixtureUIContract: Codable, Equatable, Sendable {
    static let owners: Set<String> = [
        "keepAwake", "audioMixer", "focusDim", "windowSweaters", "micMute",
        "keystrokeHighlight", "presenter", "colorPicker", "systemStats", "emoji",
        "homebrew", "calendar", "jev", "system", "timeLapse", "cleaner", "appMaintenance",
        "blitztree", "plugins", "notchShelf", "clipboard", "music", "docs", "latex",
        "companion", "terminal", "studio", "usage", "bifrost", "lidAwake", "attention",
        "machines", "downloads", "seoAudit", "virtualCamera", "codeStats", "herdr",
        "quinjet", "database",
    ]
    public let schema: Int
    public let sourceCommit: String
    public let session: String
    public let owner: String
    public let phase: String
    public let presentationID: String
    public let location: String
    public let section: String
    public let capabilitySHA256: String
    public let root: String
    public let hostIdentifier: String
    public let home: String
    public let dataDirectory: String
    public let workerPath: String
    public let rolePath: String
    public let version: String
    public let hostABI: String
    public let packageSHA256: String
    public let producer: WorkerFixtureUIProcess
    public let engine: WorkerFixtureUIProcess
    public let ui: WorkerFixtureUIProcess

    public static func validateUIContext(
        _ context: NSDictionary, environment: [String: String], owner: String,
        workerIdentifier: String
    ) throws {
        guard Self.owners.contains(owner),
            let host = context["hostIdentifier"] as? String,
            host.hasPrefix("com.pulkit.edith.tests.worker-"),
            uuid(String(host.dropFirst("com.pulkit.edith.tests.worker-".count))),
            workerIdentifier == host + ".extension." + owner + ".worker",
            let remote = context["remoteUI"] as? NSNumber,
            CFGetTypeID(remote) == CFBooleanGetTypeID(), remote.boolValue,
            let only = context["uiOnly"] as? NSNumber,
            CFGetTypeID(only) == CFBooleanGetTypeID(), !only.boolValue,
            context["extensionID"] as? String == owner,
            let location = context["location"] as? String,
            ["main", "settings"].contains(location),
            let section = context["section"] as? String,
            section == owner
                || (location == "settings"
                    && ["general", "appearance", "extensions"].contains(section)),
            let presentation = context["presentationID"] as? String,
            uuid(presentation.lowercased()),
            context["defaultsSuite"] as? String == workerIdentifier,
            environment["EDITH_APPLICATION_IDENTIFIER"] == host,
            environment["EDITH_EXTENSION_ID"] == owner,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == workerIdentifier
        else { throw WorkerFixtureError.invalid }
    }

    public static func verify(_ bytes: Data, issuerKey: Data) throws -> Self {
        guard issuerKey.count == 32, !bytes.isEmpty, bytes.count <= 131_072,
            let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(envelope.keys) == ["schema", "payload", "signature"],
            let schema = envelope["schema"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema == 1,
            let payload = envelope["payload"] as? String, !payload.isEmpty,
            payload.utf8.count <= 65_536,
            let encodedSignature = envelope["signature"] as? String,
            let signature = Data(base64Encoded: encodedSignature), signature.count == 64,
            signature.base64EncodedString() == encodedSignature,
            try canonicalJSON(envelope) == bytes
        else { throw WorkerFixtureError.invalid }
        let data = Data(payload.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == [
                "schema", "sourceCommit", "session", "owner", "phase", "presentationID",
                "location", "section", "capabilitySHA256",
                "root", "hostIdentifier", "home", "dataDirectory", "workerPath", "rolePath",
                "version", "hostABI", "packageSHA256", "producer", "engine", "ui",
            ],
            let payloadSchema = object["schema"] as? NSNumber,
            CFGetTypeID(payloadSchema) != CFBooleanGetTypeID(), payloadSchema == 1,
            ["producer", "engine", "ui"].allSatisfy({ field in
                guard let process = object[field] as? [String: Any] else { return false }
                return Set(process.keys) == [
                    "pid", "birthSeconds", "birthMicroseconds", "uid", "executable",
                    "executableSHA256",
                ]
            }),
            try canonicalJSON(object) == data,
            try Curve25519.Signing.PublicKey(rawRepresentation: issuerKey)
                .isValidSignature(signature, for: data)
        else { throw WorkerFixtureError.invalid }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func validate(
        sourceCommit expectedSource: String, session expectedSession: String,
        owner expectedOwner: String, presentationID expectedPresentation: String,
        phase expectedPhase: String, location expectedLocation: String,
        section expectedSection: String, capabilitySHA256 expectedCapability: String,
        root expectedRoot: String, dataDirectory expectedData: String,
        workerPath expectedWorker: String, rolePath expectedRole: String,
        version expectedVersion: String, uid: UInt32,
        producer observedProducer: WorkerFixtureUIProcess,
        engine observedEngine: WorkerFixtureUIProcess, ui observedUI: WorkerFixtureUIProcess
    ) throws {
        guard schema == 1, Self.owners.contains(owner), owner == expectedOwner,
            sourceCommit == expectedSource, Self.hex(sourceCommit, count: 40),
            session == expectedSession, Self.uuid(session),
            presentationID == expectedPresentation, Self.uuid(presentationID),
            ["initial", "updated", "reinstalled"].contains(phase), phase == expectedPhase,
            location == expectedLocation, ["main", "settings"].contains(location),
            section == expectedSection,
            section == owner
                || (location == "settings"
                    && ["general", "appearance", "extensions"].contains(section)),
            capabilitySHA256 == expectedCapability, Self.hex(capabilitySHA256, count: 64),
            root == expectedRoot, Self.canonical(root),
            root.hasSuffix("/functional-fixture-" + session),
            hostIdentifier == "com.pulkit.edith.tests.worker-" + session,
            home == root + "/" + owner + "-home",
            dataDirectory == expectedData, Self.canonical(dataDirectory),
            dataDirectory.hasPrefix(root + "/"),
            workerPath == expectedWorker, Self.canonical(workerPath),
            workerPath.hasPrefix(root + "/"),
            workerPath.hasSuffix(
                "/Extensions/" + owner + "/edith-host-2/arm64/" + version + "/" + owner
                    + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex"),
            rolePath == expectedRole,
            rolePath == workerPath + "/Contents/Resources/Payload/" + owner + "/app.bundle",
            hostABI == "edith-host-2", version == expectedVersion, Self.version(version),
            dataDirectory == root + "/data/" + owner,
            Self.hex(packageSHA256, count: 64),
            producer == observedProducer, engine == observedEngine, ui == observedUI,
            Set([producer.pid, engine.pid, ui.pid]).count == 3,
            engine.executable == workerPath + "/Contents/MacOS/Edith",
            ui.executable == workerPath + "/Contents/MacOS/Edith"
        else { throw WorkerFixtureError.invalid }
        try producer.validate(uid: uid)
        try engine.validate(uid: uid)
        try ui.validate(uid: uid)
    }

    static func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func canonical(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 && !path.hasSuffix("/")
            && !path.contains("//") && path.utf8.allSatisfy { $0 >= 32 && $0 < 127 }
            && !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    static func uuid(_ text: String) -> Bool {
        UUID(uuidString: text)?.uuidString.lowercased() == text
            && text.utf8.count == 36 && text[text.index(text.startIndex, offsetBy: 14)] == "4"
            && "89ab".contains(text[text.index(text.startIndex, offsetBy: 19)])
    }

    static func hex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count
            && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func version(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3
            && parts.allSatisfy { part in
                !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
                    && (part == "0" || !part.hasPrefix("0")) && UInt64(part) != nil
            }
    }
}
