import CoreFoundation
import CryptoKit
import Foundation
import WorkerFixtureSupport

public enum HostedFunctionalActionError: Error { case invalid }

public enum HostedFunctionalJSON {
    public static func object(_ data: Data) throws -> [String: Any] {
        do { return try WorkerFixtureJSON.object(data) } catch {
            throw HostedFunctionalActionError.invalid
        }
    }
}

public struct HostedFunctionalProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let birthSeconds: Int64
    public let birthMicroseconds: Int32
    public let uid: UInt32
    public let executableSHA256: String

    public init(
        pid: Int32, birthSeconds: Int64, birthMicroseconds: Int32, uid: UInt32,
        executableSHA256: String
    ) {
        self.pid = pid
        self.birthSeconds = birthSeconds
        self.birthMicroseconds = birthMicroseconds
        self.uid = uid
        self.executableSHA256 = executableSHA256
    }

    public func validate(uid: UInt32) throws {
        guard pid > 1, birthSeconds > 0, (0..<1_000_000).contains(birthMicroseconds),
            self.uid == uid, HostedFunctionalActionContext.validHash(executableSHA256)
        else { throw HostedFunctionalActionError.invalid }
    }
}

public struct HostedFunctionalOwnedPath: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let kind: String

    public init(name: String, path: String, kind: String) {
        self.name = name
        self.path = path
        self.kind = kind
    }
}

public struct HostedFunctionalActionContext: Codable, Equatable, Sendable {
    public let schema: Int
    public let sourceCommit: String
    public let session: String
    public let owner: String
    public let uid: UInt32
    public let fixtureRoot: String
    public let hostIdentifier: String
    public let home: String
    public let dataDirectory: String
    public let hostABI: String
    public let caseSHA256: String
    public let activationOperation: String?
    public let phase: String
    public let pairScope: String
    public let previousVersion: String
    public let currentVersion: String
    public let version: String
    public let packageSHA256: String
    public let engine: HostedFunctionalProcessIdentity
    public let ui: HostedFunctionalProcessIdentity
    public let operations: [String]
    public let ownedPaths: [HostedFunctionalOwnedPath]

    enum CodingKeys: String, CodingKey {
        case schema, sourceCommit, session, owner, uid, fixtureRoot, hostIdentifier, home,
            dataDirectory, hostABI, caseSHA256, activationOperation, phase, pairScope,
            previousVersion, currentVersion, version, packageSHA256, engine, ui, operations,
            ownedPaths
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema)
        try values.encode(sourceCommit, forKey: .sourceCommit)
        try values.encode(session, forKey: .session)
        try values.encode(owner, forKey: .owner)
        try values.encode(uid, forKey: .uid)
        try values.encode(fixtureRoot, forKey: .fixtureRoot)
        try values.encode(hostIdentifier, forKey: .hostIdentifier)
        try values.encode(home, forKey: .home)
        try values.encode(dataDirectory, forKey: .dataDirectory)
        try values.encode(hostABI, forKey: .hostABI)
        try values.encode(caseSHA256, forKey: .caseSHA256)
        try values.encode(activationOperation, forKey: .activationOperation)
        try values.encode(phase, forKey: .phase)
        try values.encode(pairScope, forKey: .pairScope)
        try values.encode(previousVersion, forKey: .previousVersion)
        try values.encode(currentVersion, forKey: .currentVersion)
        try values.encode(version, forKey: .version)
        try values.encode(packageSHA256, forKey: .packageSHA256)
        try values.encode(engine, forKey: .engine)
        try values.encode(ui, forKey: .ui)
        try values.encode(operations, forKey: .operations)
        try values.encode(ownedPaths, forKey: .ownedPaths)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 131_072,
            let object = try? HostedFunctionalJSON.object(data),
            Set(object.keys) == [
                "schema", "sourceCommit", "session", "owner", "uid", "fixtureRoot",
                "hostIdentifier", "home", "dataDirectory", "hostABI", "caseSHA256",
                "activationOperation", "phase",
                "pairScope", "previousVersion", "currentVersion", "version", "packageSHA256",
                "engine", "ui", "operations", "ownedPaths",
            ],
            let engine = object["engine"] as? [String: Any],
            let ui = object["ui"] as? [String: Any],
            let paths = object["ownedPaths"] as? [[String: Any]],
            Set(engine.keys) == [
                "pid", "birthSeconds", "birthMicroseconds", "uid", "executableSHA256",
            ],
            Set(ui.keys) == Set(engine.keys),
            paths.allSatisfy({ Set($0.keys) == ["name", "path", "kind"] }),
            try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) == data
        else { throw HostedFunctionalActionError.invalid }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func validate(
        source: String, owner: String, session: String, uid: UInt32, root: String,
        caseSHA256: String, operations expectedOperations: [String],
        engine: HostedFunctionalProcessIdentity,
        ui: HostedFunctionalProcessIdentity
    ) throws {
        guard schema == 1, sourceCommit == source, Self.hex(source, length: 40),
            self.owner == owner, Self.owners.contains(owner), self.session == session,
            Self.uuid(session), self.uid == uid, fixtureRoot == root,
            Self.canonical(root), root.hasSuffix("/functional-fixture-" + session),
            hostIdentifier == "com.pulkit.edith.tests.worker-" + session,
            home == root + "/" + owner + "-home",
            Self.owned(dataDirectory, root: root), hostABI == "edith-host-2",
            self.caseSHA256 == caseSHA256, Self.validHash(caseSHA256),
            ["initial", "updated", "reinstalled"].contains(phase),
            ["synthetic-development", "public-signed-pair"].contains(pairScope),
            Self.increasingVersion(previousVersion, currentVersion),
            pairScope != "synthetic-development"
                || (previousVersion == "1.0.0" && currentVersion == "1.1.0"),
            version == (phase == "initial" ? previousVersion : currentVersion),
            Self.validHash(packageSHA256), self.engine == engine, self.ui == ui,
            engine.pid != ui.pid, operations == expectedOperations,
            !operations.isEmpty, operations.count <= 16,
            Set(operations).count == operations.count,
            (owner == "calendar"
                ? activationOperation == nil && operations == ["calendar.ui.list"]
                : activationOperation.map({ operations.contains($0) }) == true),
            operations.allSatisfy(Self.operation), ownedPaths.count <= 32,
            Set(ownedPaths.map(\.name)).count == ownedPaths.count,
            Set(ownedPaths.map(\.path)).count == ownedPaths.count,
            ownedPaths.allSatisfy({
                Self.text($0.name, maximum: 256) && Self.owned($0.path, root: root)
                    && ["file", "directory"].contains($0.kind)
            })
        else { throw HostedFunctionalActionError.invalid }
        try engine.validate(uid: uid)
        try ui.validate(uid: uid)
    }

    public func ownedPath(named name: String, kind: String) throws -> URL {
        guard let entry = ownedPaths.first(where: { $0.name == name && $0.kind == kind }),
            Self.owned(entry.path, root: fixtureRoot)
        else { throw HostedFunctionalActionError.invalid }
        return URL(fileURLWithPath: entry.path, isDirectory: kind == "directory")
    }

    public func requireOperation(_ operation: String) throws {
        guard operations.contains(operation) else { throw HostedFunctionalActionError.invalid }
    }

    public static let owners: Set<String> = [
        "keepAwake", "audioMixer", "focusDim", "windowSweaters", "micMute",
        "keystrokeHighlight", "presenter", "colorPicker", "systemStats", "emoji",
        "homebrew", "calendar", "jev", "system", "timeLapse", "cleaner", "appMaintenance",
        "blitztree", "plugins", "notchShelf", "clipboard", "music", "docs", "latex",
        "companion", "terminal", "studio", "usage", "bifrost", "lidAwake", "attention",
        "machines", "downloads", "seoAudit", "virtualCamera", "codeStats", "herdr",
        "quinjet", "database",
    ]

    public static func validHash(_ value: String) -> Bool { hex(value, length: 64) }

    private static func hex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func uuid(_ value: String) -> Bool {
        guard let parsed = UUID(uuidString: value), parsed.uuidString.lowercased() == value,
            value.utf8.count == 36
        else { return false }
        let bytes = Array(value.utf8)
        return bytes[14] == 52 && [56, 57, 97, 98].contains(bytes[19])
    }

    private static func text(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    private static func canonical(_ value: String) -> Bool {
        guard text(value, maximum: 4096), value.hasPrefix("/"), !value.hasSuffix("/") else {
            return false
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.first == ""
            && parts.dropFirst().allSatisfy { $0 != "" && $0 != "." && $0 != ".." }
    }

    private static func owned(_ value: String, root: String) -> Bool {
        canonical(value) && value.hasPrefix(root + "/")
    }

    private static func increasingVersion(_ before: String, _ after: String) -> Bool {
        func parts(_ value: String) -> [UInt64]? {
            guard value.utf8.count <= 80 else { return nil }
            let fields = value.split(separator: ".", omittingEmptySubsequences: false)
            guard fields.count == 3,
                fields.allSatisfy({
                    !$0.isEmpty && ($0 == "0" || $0.first != "0")
                        && $0.utf8.allSatisfy { (48...57).contains($0) }
                })
            else { return nil }
            let numbers = fields.compactMap { UInt64($0) }
            return numbers.count == 3 ? numbers : nil
        }
        guard let a = parts(before), let b = parts(after) else { return false }
        return a.lexicographicallyPrecedes(b)
    }

    private static func operation(_ value: String) -> Bool {
        guard text(value, maximum: 128) else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2
            && parts.allSatisfy { part in
                guard let first = part.utf8.first,
                    (65...90).contains(first) || (97...122).contains(first)
                else { return false }
                return part.utf8.allSatisfy {
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                        || [45, 95].contains($0)
                }
            }
    }
}

@MainActor
public protocol HostedFunctionalActionCase {
    static var owner: String { get }
    static var activationOperation: String { get }
    func activateOriginalControl(context: HostedFunctionalActionContext) async throws
    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data
    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data?
    func shutdownPresentation() async
}

public struct HostedFunctionalMutationJournal: Codable, Equatable, Sendable {
    public struct Baseline: Codable, Equatable, Sendable {
        public let reader: String
        public let observationID: String
        public let sequence: Int
        public let readbackSHA256: String?
        public let expectedSHA256: String?

        enum CodingKeys: String, CodingKey {
            case reader, observationID, sequence, readbackSHA256, expectedSHA256
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(reader, forKey: .reader)
            try values.encode(observationID, forKey: .observationID)
            try values.encode(sequence, forKey: .sequence)
            try values.encode(readbackSHA256, forKey: .readbackSHA256)
            try values.encode(expectedSHA256, forKey: .expectedSHA256)
        }
    }

    public struct Request: Codable, Equatable, Sendable {
        public let schema: Int
        public let sourceCommit: String
        public let session: String
        public let owner: String
        public let phase: String
        public let capabilitySHA256: String
        public let requestID: String
        public let operation: String
        public let payloadSHA256: String
    }

    public struct Acknowledgement: Codable, Equatable, Sendable {
        public let request: Request
        public let engine: HostedFunctionalProcessIdentity
        public let success: Bool
        public let responseSHA256: String
        public let sequence: Int
    }

    public struct Observation: Codable, Equatable, Sendable {
        public let observationID: String
        public let sequence: Int
        public let observationSHA256: String
        public let expectedSHA256: String
    }

    public struct Transition: Codable, Equatable, Sendable {
        public let kind: String
        public let reader: String
        public let capabilitySHA256: String
        public let requestID: String
        public let before: Observation
        public let after: Observation
    }

    public struct Record: Codable, Equatable, Sendable {
        public let request: Request
        public let activationID: String
        public let origin: String
        public let ui: HostedFunctionalProcessIdentity
        public let engine: HostedFunctionalProcessIdentity
        public let payload: String
        public let sendSequence: Int
        public let acknowledgement: Acknowledgement
        public let transition: Transition
    }

    public let schema: Int
    public let sourceCommit: String
    public let session: String
    public let owner: String
    public let phase: String
    public let capabilitySHA256: String
    public let presentationID: String
    public let baseline: Baseline
    public let loadSequence: Int
    public let records: [Record]
    public let sealedThroughSequence: Int

    public static func verify(_ bytes: Data, issuerKey: Data) throws -> Self {
        guard issuerKey.count == 32, bytes.count <= 2_097_152,
            let envelope = try? HostedFunctionalJSON.object(bytes),
            Set(envelope.keys) == ["schema", "payload", "signature"],
            let schema = envelope["schema"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema == 1,
            let payload = envelope["payload"] as? String,
            !payload.isEmpty, payload.utf8.count <= 1_048_576,
            let encoded = envelope["signature"] as? String,
            let signature = Data(base64Encoded: encoded), signature.count == 64,
            signature.base64EncodedString() == encoded
        else { throw HostedFunctionalActionError.invalid }
        let data = Data(payload.utf8)
        _ = try HostedFunctionalJSON.object(data)
        let journal = try JSONDecoder().decode(Self.self, from: data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(journal) == data,
            try Curve25519.Signing.PublicKey(rawRepresentation: issuerKey)
                .isValidSignature(signature, for: data)
        else { throw HostedFunctionalActionError.invalid }
        return journal
    }

    public func validate(
        context: HostedFunctionalActionContext, capabilitySHA256: String,
        presentationID: String, persistenceApplicable: Bool, mutationKind: String,
        payloadKeys: [String], selectedRequestID: String, persistenceSequence: Int
    ) throws -> Record {
        guard schema == 1, sourceCommit == context.sourceCommit, session == context.session,
            owner == context.owner, phase == context.phase,
            self.capabilitySHA256 == capabilitySHA256,
            HostedFunctionalActionContext.validHash(capabilitySHA256),
            self.presentationID == presentationID, Self.uuid(presentationID),
            baseline.reader == "independent-hosted-producer", Self.uuid(baseline.observationID),
            baseline.sequence > 0, baseline.sequence < loadSequence,
            !records.isEmpty, records.count <= 128,
            ["state-transition", "owned-output"].contains(mutationKind),
            payloadKeys.count <= 32, Set(payloadKeys).count == payloadKeys.count,
            payloadKeys.allSatisfy({
                $0.range(of: "^[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil
            }),
            !payloadKeys.isEmpty
                || (owner == "terminal" && context.activationOperation == "terminal.open")
        else { throw HostedFunctionalActionError.invalid }
        if persistenceApplicable {
            guard let hash = baseline.readbackSHA256,
                HostedFunctionalActionContext.validHash(hash), baseline.expectedSHA256 == hash
            else { throw HostedFunctionalActionError.invalid }
        } else {
            guard baseline.readbackSHA256 == nil, baseline.expectedSHA256 == nil else {
                throw HostedFunctionalActionError.invalid
            }
        }
        var sequence = loadSequence
        var identifiers: Set<String> = [baseline.observationID]
        for record in records {
            let request = record.request
            let acknowledgement = record.acknowledgement
            let transition = record.transition
            guard request.schema == 1, request.sourceCommit == sourceCommit,
                request.session == session, request.owner == owner, request.phase == phase,
                request.capabilitySHA256 == capabilitySHA256, Self.uuid(request.requestID),
                identifiers.insert(request.requestID).inserted,
                context.operations.contains(request.operation),
                !request.operation.split(separator: ".").contains(where: {
                    ["read", "snapshot", "state", "list", "schema", "get", "poll"].contains(
                        String($0))
                }),
                Self.uuid(record.activationID), record.origin == "authenticated-original-control",
                record.ui == context.ui, record.engine == context.engine,
                let bytes = Data(base64Encoded: record.payload), !bytes.isEmpty,
                bytes.count <= 1_048_576, bytes.base64EncodedString() == record.payload,
                Self.digest(bytes) == request.payloadSHA256,
                acknowledgement.request == request, acknowledgement.engine == context.engine,
                acknowledgement.success,
                HostedFunctionalActionContext.validHash(acknowledgement.responseSHA256),
                record.sendSequence > 0, record.sendSequence < acknowledgement.sequence,
                ["state-transition", "owned-output"].contains(transition.kind),
                transition.reader == "independent-hosted-producer",
                transition.capabilitySHA256 == capabilitySHA256,
                transition.requestID == request.requestID
            else { throw HostedFunctionalActionError.invalid }
            let object = try HostedFunctionalJSON.object(bytes)
            if request.operation == context.activationOperation {
                guard Set(object.keys) == Set(payloadKeys) else {
                    throw HostedFunctionalActionError.invalid
                }
            }
            for observation in [transition.before, transition.after] {
                guard Self.uuid(observation.observationID),
                    identifiers.insert(observation.observationID).inserted,
                    observation.sequence > 0,
                    HostedFunctionalActionContext.validHash(observation.observationSHA256),
                    observation.expectedSHA256 == observation.observationSHA256
                else { throw HostedFunctionalActionError.invalid }
            }
            guard sequence < transition.before.sequence,
                transition.before.sequence < record.sendSequence,
                acknowledgement.sequence < transition.after.sequence
            else { throw HostedFunctionalActionError.invalid }
            sequence = transition.after.sequence
        }
        guard sealedThroughSequence > sequence, sealedThroughSequence >= persistenceSequence,
            let selected = records.last, selected.request.requestID == selectedRequestID,
            selected.request.operation == context.activationOperation,
            selected.transition.kind == mutationKind,
            selected.transition.before.observationSHA256
                != selected.transition.after.observationSHA256
        else { throw HostedFunctionalActionError.invalid }
        return selected
    }

    private static func uuid(_ value: String) -> Bool {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value,
            value.utf8.count == 36
        else { return false }
        let bytes = Array(value.utf8)
        return bytes[14] == 52 && [56, 57, 97, 98].contains(bytes[19])
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct HostedFunctionalCalendarControlSnapshot: Equatable, Sendable {
    public let bytes: Data
    public let visibleStaticTexts: [String]

    public static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 131_072 else {
            throw HostedFunctionalActionError.invalid
        }
        let value = try HostedFunctionalJSON.object(bytes)
        guard Set(value.keys) == ["schema", "kind", "visibleStaticTexts"],
            let schema = value["schema"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema == 1,
            value["kind"] as? String == "calendar-details",
            let labels = value["visibleStaticTexts"] as? [String], labels.count <= 512,
            labels.allSatisfy({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }),
            try JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) == bytes
        else { throw HostedFunctionalActionError.invalid }
        return .init(bytes: bytes, visibleStaticTexts: labels)
    }
}

public struct HostedFunctionalOriginalUIReceipt: Sendable {
    public let context: HostedFunctionalActionContext
    public let recipeSHA256: String
    public let beforeBackend: Data
    public let afterBackend: Data
    public let beforeControl: HostedFunctionalCalendarControlSnapshot
    public let afterControl: HostedFunctionalCalendarControlSnapshot
    public let signedBytes: Data

    public static func verify(
        signedBytes: Data, issuerKey: Data, context: HostedFunctionalActionContext,
        presentationID: String, capabilitySHA256: String, recipeSHA256: String
    ) throws -> Self {
        let value = try envelope(signedBytes, key: issuerKey)
        guard
            Set(value.keys) == [
                "schema", "kind", "sourceCommit", "session", "owner", "phase",
                "caseSHA256", "presentationID", "capabilitySHA256", "recipeSHA256", "authorization",
                "completion", "beforeBackend", "afterBackend", "beforeControl", "afterControl",
            ],
            try integer(value, "schema") == 1,
            value["kind"] as? String == "original-calendar-local-control",
            context.owner == "calendar", value["sourceCommit"] as? String == context.sourceCommit,
            value["session"] as? String == context.session,
            value["owner"] as? String == context.owner,
            value["phase"] as? String == context.phase,
            value["caseSHA256"] as? String == context.caseSHA256,
            value["presentationID"] as? String == presentationID,
            UUID(uuidString: presentationID)?.uuidString.lowercased() == presentationID,
            value["capabilitySHA256"] as? String == capabilitySHA256,
            value["recipeSHA256"] as? String == recipeSHA256,
            HostedFunctionalActionContext.validHash(capabilitySHA256),
            HostedFunctionalActionContext.validHash(recipeSHA256),
            let authorization = value["authorization"] as? [String: Any],
            let completion = value["completion"] as? [String: Any]
        else { throw HostedFunctionalActionError.invalid }
        let beforeControl = try HostedFunctionalCalendarControlSnapshot.decode(
            binary(value, "beforeControl", maximum: 131_072))
        let afterControl = try HostedFunctionalCalendarControlSnapshot.decode(
            binary(value, "afterControl", maximum: 131_072))
        let before = try boundary(
            authorization, operation: "authorize-original-step", key: issuerKey,
            context: context, presentationID: presentationID, capabilitySHA256: capabilitySHA256,
            control: beforeControl.bytes)
        let after = try boundary(
            completion, operation: "complete-original-step", key: issuerKey,
            context: context, presentationID: presentationID, capabilitySHA256: capabilitySHA256,
            control: afterControl.bytes)
        guard before["actor"] as? [String: Any] != nil,
            try JSONSerialization.data(
                withJSONObject: before["actor"]!, options: [.sortedKeys, .withoutEscapingSlashes])
                == JSONSerialization.data(
                    withJSONObject: after["actor"]!,
                    options: [.sortedKeys, .withoutEscapingSlashes]),
            before["authorizationID"] as? String == after["authorizationID"] as? String,
            before["stepSHA256"] as? String == after["stepSHA256"] as? String,
            before["sourceSHA256"] as? String == after["sourceSHA256"] as? String
        else { throw HostedFunctionalActionError.invalid }
        return .init(
            context: context, recipeSHA256: recipeSHA256,
            beforeBackend: try binary(value, "beforeBackend", maximum: 1_048_576),
            afterBackend: try binary(value, "afterBackend", maximum: 1_048_576),
            beforeControl: beforeControl, afterControl: afterControl, signedBytes: signedBytes)
    }

    private static func integer(_ value: [String: Any], _ key: String) throws -> Int {
        guard let number = value[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite, number.doubleValue == Double(number.intValue)
        else { throw HostedFunctionalActionError.invalid }
        return number.intValue
    }

    private static func uuid(_ value: String) -> Bool {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value, value.utf8.count == 36
        else { return false }
        let bytes = Array(value.utf8)
        return bytes[14] == 52 && [56, 57, 97, 98].contains(bytes[19])
    }

    private static func binary(_ value: [String: Any], _ key: String, maximum: Int) throws -> Data {
        guard let text = value[key] as? String, let bytes = Data(base64Encoded: text),
            !bytes.isEmpty, bytes.count <= maximum, bytes.base64EncodedString() == text
        else { throw HostedFunctionalActionError.invalid }
        return bytes
    }

    private static func envelope(_ bytes: Data, key: Data) throws -> [String: Any] {
        guard key.count == 32, bytes.count <= 4_194_304 else {
            throw HostedFunctionalActionError.invalid
        }
        let object = try HostedFunctionalJSON.object(bytes)
        guard Set(object.keys) == ["schema", "payload", "signature"],
            let schema = object["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(),
            schema == 1,
            let payload = object["payload"] as? String, !payload.isEmpty,
            let text = object["signature"] as? String, let signature = Data(base64Encoded: text),
            signature.count == 64, signature.base64EncodedString() == text
        else { throw HostedFunctionalActionError.invalid }
        let data = Data(payload.utf8)
        let value = try HostedFunctionalJSON.object(data)
        guard
            try JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) == data,
            try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(
                signature, for: data)
        else { throw HostedFunctionalActionError.invalid }
        return value
    }

    private static func boundary(
        _ object: [String: Any], operation: String, key: Data,
        context: HostedFunctionalActionContext, presentationID: String,
        capabilitySHA256: String, control: Data
    ) throws -> [String: Any] {
        let value = try envelope(
            JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), key: key)
        guard
            Set(value.keys) == [
                "schema", "sourceCommit", "session", "requestID", "operation", "owner", "phase",
                "authorizationID", "actor", "stepIndex", "stepSHA256", "sourceSHA256",
                "presentationID",
                "capabilitySHA256", "firstEventOrdinal", "lastEventOrdinal", "localControlSHA256",
            ],
            value["sourceCommit"] as? String == context.sourceCommit,
            value["session"] as? String == context.session,
            value["owner"] as? String == context.owner,
            value["phase"] as? String == context.phase, value["operation"] as? String == operation,
            value["presentationID"] as? String == presentationID,
            value["capabilitySHA256"] as? String == capabilitySHA256,
            try integer(value, "schema") == 1, try integer(value, "stepIndex") == 0,
            let requestID = value["requestID"] as? String, uuid(requestID),
            let authorizationID = value["authorizationID"] as? String, uuid(authorizationID),
            let sourceSHA256 = value["sourceSHA256"] as? String,
            HostedFunctionalActionContext.validHash(sourceSHA256),
            let stepSHA256 = value["stepSHA256"] as? String,
            HostedFunctionalActionContext.validHash(stepSHA256),
            try integer(value, "firstEventOrdinal") >= 0,
            try integer(value, "lastEventOrdinal") >= integer(value, "firstEventOrdinal"),
            let actor = value["actor"] as? [String: Any],
            Set(actor.keys) == [
                "pid", "birthSeconds", "birthMicroseconds", "uid", "executable", "executableSHA256",
            ],
            let path = actor["executable"] as? String,
            path.hasPrefix(context.fixtureRoot + "/XCTest/"),
            try integer(actor, "uid") == Int(context.uid),
            try integer(actor, "pid") > 1, try integer(actor, "pid") != Int(context.engine.pid),
            try integer(actor, "pid") != Int(context.ui.pid),
            try integer(actor, "birthSeconds") > 0,
            (0..<1_000_000).contains(try integer(actor, "birthMicroseconds")),
            let executableHash = actor["executableSHA256"] as? String,
            HostedFunctionalActionContext.validHash(executableHash),
            let hash = value["localControlSHA256"] as? String,
            hash == SHA256.hash(data: control).map({ String(format: "%02x", $0) }).joined()
        else { throw HostedFunctionalActionError.invalid }
        return value
    }
}
