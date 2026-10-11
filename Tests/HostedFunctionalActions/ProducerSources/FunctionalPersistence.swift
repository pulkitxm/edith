import CryptoKit
import Darwin
import Foundation

struct FunctionalSemanticRead {
    enum Format { case json, propertyList }
    let owner: String
    let name: String
    let file: URL
    let format: Format
    let keys: Set<String>
    let maskedKeys: Set<String>

    func read(root: FunctionalPinnedPath) throws -> Data {
        try root.requireCurrent()
        guard !owner.isEmpty, !name.isEmpty, !keys.isEmpty, maskedKeys.isSubset(of: keys),
            file.path.hasPrefix(root.url.path + "/")
        else { throw FunctionalFailure.invalid("semantic reader scope") }
        let bytes = try FunctionalPinnedPath(file, directory: false, maximum: 16_777_216).read()
        let object: [String: Any]
        switch format {
        case .json:
            guard let decoded = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { throw FunctionalFailure.invalid("semantic JSON") }
            object = decoded
        case .propertyList:
            guard let decoded = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
            else { throw FunctionalFailure.invalid("semantic property list") }
            object = decoded
        }
        guard keys.isSubset(of: Set(object.keys)) else { throw FunctionalFailure.invalid("missing owned keys") }
        var selected: [String: Any] = [:]
        for key in keys {
            guard let value = object[key] else { throw FunctionalFailure.invalid("owned key") }
            if maskedKeys.contains(key) {
                guard let text = value as? String else { throw FunctionalFailure.invalid("masked semantic value type") }
                selected[key] = ["maskedSHA256": FunctionalBytes.digest(Data(text.utf8))]
            } else { selected[key] = value }
        }
        try root.requireCurrent()
        return try FunctionalBytes.canonical(selected)
    }
}

struct FunctionalPreferenceRead {
    enum Codec { case value, dataJSON, maskedUTF8 }
    let suite: String
    let directory: FunctionalPinnedPath
    let keys: [String: Codec]

    func read(root: FunctionalPinnedPath) throws -> Data {
        try root.requireCurrent()
        try directory.requireCurrent()
        guard suite.hasPrefix("com.pulkit.edith.tests.worker-"), !suite.contains("/"),
            !suite.utf8.contains(0), suite.utf8.count <= 256, !keys.isEmpty, keys.count <= 64,
            directory.url.path.hasPrefix(root.url.path + "/"),
            directory.url.path.hasSuffix("/Library/Preferences")
        else { throw FunctionalFailure.invalid("owned preference source scope") }
        let url = directory.url.appendingPathComponent(suite + ".plist")
        var state = stat()
        let exists = lstat(url.path, &state) == 0
        guard exists || errno == ENOENT else { throw FunctionalFailure.invalid("owned preferences stat") }
        let object: [String: Any]
        if exists {
            let pinned = try FunctionalPinnedPath(url, directory: false, maximum: 1_048_576)
            let bytes = try pinned.read()
            guard let decoded = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                try pinned.read() == bytes
            else { throw FunctionalFailure.invalid("owned preferences bytes") }
            object = decoded
        } else { object = [:] }
        var selected: [String: Any] = [:]
        for (key, codec) in keys {
            guard !key.isEmpty, key.utf8.count <= 256 else { throw FunctionalFailure.invalid("owned preference key") }
            guard let value = object[key] else { selected[key] = ["present": false]; continue }
            let semantic: Any
            switch codec {
            case .value:
                semantic = value
                _ = try FunctionalBytes.canonical(semantic)
            case .dataJSON:
                guard let data = value as? Data, !data.isEmpty, data.count <= 1_048_576 else {
                    throw FunctionalFailure.invalid("saved preference JSON data") }
                semantic = try JSONSerialization.jsonObject(with: data)
                _ = try FunctionalBytes.canonical(semantic)
            case .maskedUTF8:
                guard let text = value as? String, text.utf8.count <= 4096 else {
                    throw FunctionalFailure.invalid("saved masked preference type") }
                semantic = ["maskedSHA256": FunctionalBytes.digest(Data(text.utf8))]
            }
            selected[key] = ["present": true, "value": semantic]
        }
        try directory.requireCurrent()
        try root.requireCurrent()
        return try FunctionalBytes.canonical(selected)
    }
}

final class FunctionalPersistence {
    struct Observation {
        let identifier = UUID().uuidString.lowercased()
        let sequence: Int
        let bytes: Data?
        let expectedBytes: Data?

        var digest: String? { bytes.map(FunctionalBytes.digest) }
        var object: [String: Any] {
            ["reader": "independent-hosted-producer", "observationID": identifier,
                "sequence": sequence, "readbackSHA256": digest as Any? ?? NSNull(),
                "expectedSHA256": expectedBytes.map(FunctionalBytes.digest) as Any? ?? NSNull()]
        }
    }

    private let reader: () throws -> Data?
    private(set) var baseline: Observation?
    private(set) var loadSequence: Int?
    private(set) var firstRequestID: String?
    private var boundCapabilitySHA256: String?
    private var boundEngine: FunctionalBirth?
    private var boundUI: FunctionalBirth?
    private let initialSaved: Data?
    private var latestReadSequence: Int?

    init(reader: @escaping () throws -> Data?, initialSaved: Data?) {
        self.reader = reader
        self.initialSaved = initialSaved
    }

    func captureBeforeConstruction(sequence: Int) throws -> Observation {
        guard baseline == nil, loadSequence == nil, firstRequestID == nil, sequence > 0
        else { throw FunctionalFailure.invalid("early persistence order") }
        let bytes = try reader()
        guard bytes == initialSaved else { throw FunctionalFailure.invalid("source expected saved baseline") }
        let observation = Observation(sequence: sequence, bytes: bytes, expectedBytes: initialSaved)
        baseline = observation
        return observation
    }

    func bindLoaded(capabilitySHA256: String, engine: FunctionalBirth, ui: FunctionalBirth, sequence: Int) throws {
        guard let baseline, loadSequence == nil, sequence > baseline.sequence,
            FunctionalBytes.hex(capabilitySHA256, length: 64), engine.pid != ui.pid
        else { throw FunctionalFailure.invalid("load baseline binding") }
        try engine.requireCurrent()
        try ui.requireCurrent()
        guard try reader() == baseline.bytes else { throw FunctionalFailure.invalid("construction changed persistence") }
        boundCapabilitySHA256 = capabilitySHA256
        boundEngine = engine
        boundUI = ui
        loadSequence = sequence
    }

    func beforeFirstRequest(_ requestID: String) throws -> [String: Any] {
        guard let baseline, loadSequence != nil, firstRequestID == nil,
            let capability = boundCapabilitySHA256, let engine = boundEngine, let ui = boundUI,
            FunctionalBytes.uuid(requestID)
        else { throw FunctionalFailure.invalid("first request baseline") }
        try engine.requireCurrent()
        try ui.requireCurrent()
        guard try reader() == baseline.bytes else { throw FunctionalFailure.invalid("saved state changed before first mutation") }
        firstRequestID = requestID
        return baseline.object.merging([
            "capabilitySHA256": capability, "engine": engine.contractObject,
            "ui": ui.contractObject, "beforeRequestID": requestID,
        ]) { _, new in new }
    }

    func readSaved(sequence: Int, expected: Data?) throws -> Observation {
        guard let loadSequence, firstRequestID != nil, sequence > (latestReadSequence ?? loadSequence),
            let engine = boundEngine, let ui = boundUI
        else { throw FunctionalFailure.invalid("saved observation order") }
        try engine.requireCurrent()
        try ui.requireCurrent()
        let bytes = try reader()
        guard bytes == expected else { throw FunctionalFailure.invalid("saved semantic mismatch") }
        latestReadSequence = sequence
        return Observation(sequence: sequence, bytes: bytes, expectedBytes: expected)
    }
}
