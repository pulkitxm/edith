import CryptoKit
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
            selected[key] = maskedKeys.contains(key)
                ? ["maskedSHA256": FunctionalBytes.digest(try FunctionalBytes.canonical(value))]
                : value
        }
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
    private var initialSaved: Data?

    init(reader: @escaping () throws -> Data?, initialSaved: Data?) {
        self.reader = reader
        self.initialSaved = initialSaved
    }

    func captureBeforeConstruction(sequence: Int, retained: Bool) throws -> Observation {
        guard baseline == nil, loadSequence == nil, firstRequestID == nil, sequence > 0
        else { throw FunctionalFailure.invalid("early persistence order") }
        let bytes = try reader()
        if retained {
            guard bytes == initialSaved else { throw FunctionalFailure.invalid("retained saved baseline") }
        }
        let observation = Observation(sequence: sequence, bytes: bytes, expectedBytes: retained ? initialSaved : bytes)
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
        guard let loadSequence, firstRequestID != nil, sequence > loadSequence,
            let engine = boundEngine, let ui = boundUI
        else { throw FunctionalFailure.invalid("saved observation order") }
        try engine.requireCurrent()
        try ui.requireCurrent()
        let bytes = try reader()
        guard bytes == expected else { throw FunctionalFailure.invalid("saved semantic mismatch") }
        return Observation(sequence: sequence, bytes: bytes, expectedBytes: expected)
    }
}
