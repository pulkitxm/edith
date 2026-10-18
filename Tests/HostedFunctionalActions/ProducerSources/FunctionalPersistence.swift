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
            guard
                let decoded = try PropertyListSerialization.propertyList(from: bytes, format: nil)
                    as? [String: Any]
            else { throw FunctionalFailure.invalid("semantic property list") }
            object = decoded
        }
        guard keys.isSubset(of: Set(object.keys)) else {
            throw FunctionalFailure.invalid("missing owned keys")
        }
        var selected: [String: Any] = [:]
        for key in keys {
            guard let value = object[key] else { throw FunctionalFailure.invalid("owned key") }
            if maskedKeys.contains(key) {
                guard let text = value as? String else {
                    throw FunctionalFailure.invalid("masked semantic value type")
                }
                selected[key] = ["maskedSHA256": FunctionalBytes.digest(Data(text.utf8))]
            } else {
                selected[key] = value
            }
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
        guard exists || errno == ENOENT else {
            throw FunctionalFailure.invalid("owned preferences stat")
        }
        let object: [String: Any]
        if exists {
            let pinned = try FunctionalPinnedPath(url, directory: false, maximum: 1_048_576)
            let bytes = try pinned.read()
            guard
                let decoded = try PropertyListSerialization.propertyList(from: bytes, format: nil)
                    as? [String: Any],
                try pinned.read() == bytes
            else { throw FunctionalFailure.invalid("owned preferences bytes") }
            object = decoded
        } else {
            object = [:]
        }
        var selected: [String: Any] = [:]
        for (key, codec) in keys {
            guard !key.isEmpty, key.utf8.count <= 256 else {
                throw FunctionalFailure.invalid("owned preference key")
            }
            guard let value = object[key] else { selected[key] = ["present": false]; continue }
            let semantic: Any
            switch codec {
            case .value:
                semantic = value
                _ = try FunctionalBytes.canonical(semantic)
            case .dataJSON:
                guard let data = value as? Data, !data.isEmpty, data.count <= 1_048_576 else {
                    throw FunctionalFailure.invalid("saved preference JSON data")
                }
                semantic = try JSONSerialization.jsonObject(with: data)
                _ = try FunctionalBytes.canonical(semantic)
            case .maskedUTF8:
                guard let text = value as? String, text.utf8.count <= 4096 else {
                    throw FunctionalFailure.invalid("saved masked preference type")
                }
                semantic = ["maskedSHA256": FunctionalBytes.digest(Data(text.utf8))]
            }
            selected[key] = ["present": true, "value": semantic]
        }
        try directory.requireCurrent()
        try root.requireCurrent()
        return try FunctionalBytes.canonical(selected)
    }
}

final class FunctionalOwnerSavedReader {
    final class RawObservation {
        let identifier = UUID().uuidString.lowercased()
        fileprivate let readerID: UUID
        fileprivate let scope: String
        fileprivate let root: FunctionalPinnedPath
        fileprivate let files: [FileObservation]
        let saved: Data?

        fileprivate init(
            readerID: UUID, scope: String, root: FunctionalPinnedPath, files: [FileObservation],
            saved: Data?
        ) {
            self.readerID = readerID
            self.scope = scope
            self.root = root
            self.files = files
            self.saved = saved
        }

        func rawBytes(name: String) throws -> Data? {
            guard let file = files.first(where: { $0.name == name }) else {
                throw FunctionalFailure.invalid("unknown raw saved source name")
            }
            return file.bytes
        }

        var object: [String: Any] {
            [
                "reader": "independent-hosted-producer", "observationID": identifier,
                "readbackSHA256": saved.map(FunctionalBytes.digest) as Any? ?? NSNull(),
                "files": files.map(\.object),
            ]
        }
    }

    fileprivate struct FileObservation: Equatable {
        let name: String
        let path: String
        let bytes: Data?
        let identity: [String: String]

        var object: [String: Any] {
            [
                "name": name, "path": path, "present": bytes != nil,
                "bytes": bytes?.count ?? 0,
                "sha256": bytes.map(FunctionalBytes.digest) as Any? ?? NSNull(),
                "identity": identity,
            ]
        }
    }

    private struct Selection {
        let name: String
        let path: [String]
        let codec: String
        let decodedPath: [String]
    }

    private struct FileDefinition {
        let name: String
        let file: URL
        let maximumBytes: Int
        let format: String?
        let selections: [Selection]
    }

    private let readerID = UUID()
    private let scope: String
    private let root: FunctionalPinnedPath
    private let files: [FileDefinition]
    private let directories: [FunctionalPinnedPath]
    let definitionSHA256: String
    let initialSaved: Data?
    let finalSaved: Data?

    init(
        owner: String, phase: String, root: FunctionalPinnedPath, session: String,
        hostIdentifier: String, definition: Data
    ) throws {
        try root.requireCurrent()
        _ = try FunctionalPinnedPath(root.url, directory: true, privateMode: true)
        let parsed = try Self.parse(
            owner: owner, phase: phase, rootPath: root.url.path,
            session: session, hostIdentifier: hostIdentifier, definition: definition)
        var parents: [String: FunctionalPinnedPath] = [:]
        for file in parsed.files {
            var parent = file.file.deletingLastPathComponent()
            while parent.path != root.url.path {
                guard parent.path.hasPrefix(root.url.path + "/") else {
                    throw FunctionalFailure.invalid("saved ancestor outside root")
                }
                if parents[parent.path] == nil {
                    parents[parent.path] = try FunctionalPinnedPath(parent, directory: true)
                }
                parent.deleteLastPathComponent()
            }
        }
        self.root = root
        scope = [owner, session, hostIdentifier, root.url.path, FunctionalBytes.digest(definition)]
            .joined(separator: "|")
        files = parsed.files
        directories = parents.keys.sorted().map { parents[$0]! }
        definitionSHA256 = FunctionalBytes.digest(definition)
        initialSaved = phase == "initial" ? parsed.initial : parsed.final
        finalSaved = parsed.final
        try requireDirectories()
    }

    private struct ParsedDefinition {
        let files: [FileDefinition]
        let initial: Data?
        let final: Data?
    }

    static func requiredParentDirectories(
        owner: String, phase: String, root: String, session: String,
        hostIdentifier: String, definition: Data
    ) throws -> [String] {
        let parsed = try parse(
            owner: owner, phase: phase, rootPath: root,
            session: session, hostIdentifier: hostIdentifier, definition: definition)
        var result = Set<String>()
        for file in parsed.files {
            var parent = file.file.deletingLastPathComponent()
            while parent.path != root {
                guard parent.path.hasPrefix(root + "/") else {
                    throw FunctionalFailure.invalid("saved ancestor outside root")
                }
                result.insert(parent.path)
                parent.deleteLastPathComponent()
            }
        }
        return result.sorted {
            ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1)
        }
    }

    private static func parse(
        owner: String, phase: String, rootPath: String, session: String,
        hostIdentifier: String, definition: Data
    ) throws -> ParsedDefinition {
        guard rootPath.hasPrefix("/"), rootPath != "/", !rootPath.utf8.contains(0),
            !rootPath.contains("//"),
            rootPath == URL(fileURLWithPath: rootPath).standardizedFileURL.path
        else { throw FunctionalFailure.invalid("canonical saved source root") }
        guard !owner.isEmpty, owner.utf8.count <= 64,
            owner.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }),
            ["initial", "updated", "reinstalled"].contains(phase), FunctionalBytes.uuid(session),
            hostIdentifier == "com.pulkit.edith.tests.worker-" + session
        else { throw FunctionalFailure.invalid("source saved reader identity") }
        let object = try FunctionalBytes.object(definition, maximum: 262_144)
        try FunctionalBytes.exact(
            object, ["schema", "owner", "reads", "sentinels", "initial", "final"])
        guard try FunctionalBytes.integer(object, "schema") == 1,
            object["owner"] as? String == owner,
            let reads = object["reads"] as? [[String: Any]],
            let sentinels = object["sentinels"] as? [[String: Any]],
            reads.count <= 16, sentinels.count <= 16,
            !reads.isEmpty || !sentinels.isEmpty || ["calendar", "audioMixer"].contains(owner)
        else { throw FunctionalFailure.invalid("finite source saved reader definition") }
        func component(_ object: Any) throws -> String {
            if let literal = object as? String {
                guard !literal.isEmpty, literal != ".", literal != "..", literal.utf8.count <= 255,
                    !literal.contains("/"), !literal.utf8.contains(0), !literal.contains("\\")
                else { throw FunctionalFailure.invalid("literal saved file component") }
                return literal
            }
            guard let derived = object as? [String: String], derived.count == 1,
                let kind = derived["derived"]
            else {
                throw FunctionalFailure.invalid("derived saved file component")
            }
            switch kind {
            case "ui-suite-plist": return hostIdentifier + ".extension." + owner + ".worker.plist"
            case "engine-suite-plist": return hostIdentifier + ".extensions." + owner + ".plist"
            case "session": return session
            case "phase": return phase
            default: throw FunctionalFailure.invalid("source saved component transform")
            }
        }
        func resolve(_ object: [String: Any]) throws -> URL {
            guard let kind = object["root"] as? String,
                let components = object["components"] as? [Any],
                !components.isEmpty, components.count <= 16
            else { throw FunctionalFailure.invalid("finite saved file path") }
            let directory: String
            switch kind {
            case "owner-home": directory = rootPath + "/" + owner + "-home"
            case "owner-data":
                directory = rootPath + "/Edith Tests/worker-" + session + "/Data/" + owner
            case "owner-inputs": directory = rootPath + "/inputs/" + owner
            case "owner-outputs": directory = rootPath + "/outputs/" + owner
            default: throw FunctionalFailure.invalid("saved file source root")
            }
            let relative = try components.map(component)
            let url = URL(fileURLWithPath: directory + "/" + relative.joined(separator: "/"))
            guard url.path.hasPrefix(rootPath + "/"), url.path == url.standardizedFileURL.path
            else {
                throw FunctionalFailure.invalid("saved file source path")
            }
            for (index, value) in components.enumerated() where value is [String: String] {
                guard let derived = value as? [String: String] else {
                    throw FunctionalFailure.invalid("derived saved component")
                }
                if !["session", "phase"].contains(derived["derived"] ?? "") {
                    guard kind == "owner-home", index == 2, relative.count == 3,
                        relative[0] == "Library", relative[1] == "Preferences"
                    else { throw FunctionalFailure.invalid("original preference suite location") }
                }
            }
            if relative.contains("Preferences") {
                guard components.last is [String: String], relative.count == 3,
                    relative[0] == "Library", relative[1] == "Preferences",
                    ["ui-suite-plist", "engine-suite-plist"].contains(
                        (components.last as? [String: String])?["derived"] ?? "")
                else { throw FunctionalFailure.invalid("caller-selected preference suite") }
            }
            return url
        }
        var parsed: [FileDefinition] = []
        for (isRead, definitions) in [(true, reads), (false, sentinels)] {
            for entry in definitions {
                try FunctionalBytes.exact(
                    entry,
                    isRead
                        ? ["name", "root", "components", "maximumBytes", "format", "selections"]
                        : ["name", "root", "components", "maximumBytes"])
                guard let name = entry["name"] as? String, !name.isEmpty, name.utf8.count <= 128,
                    !name.utf8.contains(0), !parsed.contains(where: { $0.name == name })
                else { throw FunctionalFailure.invalid("unique saved file name") }
                let maximum = try FunctionalBytes.integer(entry, "maximumBytes")
                guard maximum > 0, maximum <= 16_777_216 else {
                    throw FunctionalFailure.invalid("saved file byte bound")
                }
                let file = try resolve(entry)
                guard !parsed.contains(where: { $0.file == file }) else {
                    throw FunctionalFailure.invalid("duplicate saved file path")
                }
                var selections: [Selection] = []
                let format: String?
                if isRead {
                    guard let value = entry["format"] as? String,
                        ["json", "property-list"].contains(value),
                        let values = entry["selections"] as? [[String: Any]], !values.isEmpty,
                        values.count <= 64
                    else { throw FunctionalFailure.invalid("source saved codec") }
                    format = value
                    for selected in values {
                        try FunctionalBytes.exact(
                            selected,
                            selected["decodedPath"] == nil
                                ? ["name", "path", "codec"]
                                : ["name", "path", "codec", "decodedPath"])
                        guard let name = selected["name"] as? String, !name.isEmpty,
                            name.utf8.count <= 256,
                            !selections.contains(where: { $0.name == name }),
                            let path = selected["path"] as? [String], !path.isEmpty,
                            path.count <= 16,
                            path.allSatisfy({
                                !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0)
                            }),
                            let codec = selected["codec"] as? String,
                            ["value", "data-json", "data-property-list", "masked-utf8"].contains(
                                codec)
                        else { throw FunctionalFailure.invalid("finite saved selection") }
                        let decodedPath: [String]
                        if let supplied = selected["decodedPath"] {
                            guard ["data-json", "data-property-list"].contains(codec),
                                let path = supplied as? [String], !path.isEmpty, path.count <= 16,
                                path.allSatisfy({
                                    !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0)
                                })
                            else {
                                throw FunctionalFailure.invalid("finite saved decoded selection")
                            }
                            decodedPath = path
                        } else {
                            decodedPath = []
                        }
                        selections.append(
                            Selection(
                                name: name, path: path, codec: codec, decodedPath: decodedPath))
                    }
                } else {
                    format = nil
                }
                parsed.append(
                    FileDefinition(
                        name: name, file: file, maximumBytes: maximum, format: format,
                        selections: selections))
            }
        }
        func expand(_ value: Any, depth: Int = 0) throws -> Any {
            guard depth <= 32 else { throw FunctionalFailure.invalid("saved expectation depth") }
            if let values = value as? [Any] {
                return try values.map { try expand($0, depth: depth + 1) }
            }
            guard let values = value as? [String: Any] else { return value }
            if let binding = values["$binding"] as? String {
                switch binding {
                case "session":
                    try FunctionalBytes.exact(values, ["$binding"])
                    return session
                case "owned-path":
                    try FunctionalBytes.exact(values, ["$binding", "root", "components"])
                    return try resolve(values).path
                default: throw FunctionalFailure.invalid("source saved expectation binding")
                }
            }
            var result: [String: Any] = [:]
            for (key, value) in values { result[key] = try expand(value, depth: depth + 1) }
            return result
        }
        func expected(_ value: Any) throws -> Data? {
            if reads.isEmpty {
                guard value is NSNull else {
                    throw FunctionalFailure.invalid("sentinel-only saved expectation")
                }
                return nil
            }
            guard let values = try expand(value) as? [String: Any],
                Set(values.keys) == Set(reads.compactMap { $0["name"] as? String })
            else {
                throw FunctionalFailure.invalid("source saved expectation reader fields")
            }
            for file in parsed where file.format != nil {
                guard let selected = values[file.name] as? [String: Any],
                    Set(selected.keys) == Set(file.selections.map(\.name))
                else {
                    throw FunctionalFailure.invalid("source saved expectation selection fields")
                }
                for selection in file.selections {
                    guard let entry = selected[selection.name] as? [String: Any] else {
                        throw FunctionalFailure.invalid("source saved expectation presence")
                    }
                    let present = try FunctionalBytes.boolean(entry, "present")
                    try FunctionalBytes.exact(entry, present ? ["present", "value"] : ["present"])
                }
            }
            return try FunctionalBytes.canonical(values)
        }
        let initial = try expected(object["initial"]!)
        let final = try expected(object["final"]!)
        return ParsedDefinition(files: parsed, initial: initial, final: final)
    }

    func read() throws -> Data? { try observeSentinels().saved }

    func observeSentinels() throws -> RawObservation {
        try requireDirectories()
        let before = try files.map(observe)
        var selected: [String: Any] = [:]
        for (file, observation) in zip(files, before) where file.format != nil {
            let decoded: Any?
            if let bytes = observation.bytes {
                decoded =
                    file.format == "json"
                    ? try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
                    : try PropertyListSerialization.propertyList(from: bytes, format: nil)
                guard decoded is [String: Any] || decoded is [Any] else {
                    throw FunctionalFailure.invalid("saved container")
                }
            } else {
                decoded = nil
            }
            var values: [String: Any] = [:]
            for selection in file.selections {
                guard let value = try select(selection.path, from: decoded) else {
                    values[selection.name] = ["present": false]
                    continue
                }
                let semantic: Any
                switch selection.codec {
                case "value": semantic = value
                case "data-json", "data-property-list":
                    guard let bytes = value as? Data, !bytes.isEmpty,
                        bytes.count <= file.maximumBytes
                    else {
                        throw FunctionalFailure.invalid("saved embedded data codec")
                    }
                    semantic =
                        selection.codec == "data-json"
                        ? try JSONSerialization.jsonObject(
                            with: bytes, options: [.fragmentsAllowed])
                        : try PropertyListSerialization.propertyList(from: bytes, format: nil)
                case "masked-utf8":
                    guard let text = value as? String, text.utf8.count <= 4096 else {
                        throw FunctionalFailure.invalid("saved masked value")
                    }
                    semantic = ["maskedSHA256": FunctionalBytes.digest(Data(text.utf8))]
                default: throw FunctionalFailure.invalid("saved codec")
                }
                let projected: Any
                if selection.decodedPath.isEmpty {
                    projected = semantic
                } else if let value = try select(selection.decodedPath, from: semantic) {
                    projected = value
                } else {
                    throw FunctionalFailure.invalid("missing decoded saved selection")
                }
                _ = try FunctionalBytes.canonical(projected)
                values[selection.name] = ["present": true, "value": projected]
            }
            selected[file.name] = values
        }
        try requireDirectories()
        guard try files.map(observe) == before else {
            throw FunctionalFailure.invalid("raw saved files changed during observation")
        }
        return RawObservation(
            readerID: readerID, scope: scope, root: root, files: before,
            saved: selected.isEmpty ? nil : try FunctionalBytes.canonical(selected))
    }

    func requireUnchanged(since observation: RawObservation) throws {
        guard observation.readerID == readerID else {
            throw FunctionalFailure.invalid("foreign raw saved observation")
        }
        guard try observeSentinels().files == observation.files else {
            throw FunctionalFailure.invalid("raw saved identity changed")
        }
    }

    func requirePreserved(since observation: RawObservation) throws {
        guard observation.scope == scope else {
            throw FunctionalFailure.invalid("foreign raw saved observation")
        }
        try observation.root.requireCurrent()
        let current = try observeSentinels()
        guard current.files.count == observation.files.count,
            zip(current.files, observation.files).allSatisfy({
                $0.name == $1.name && $0.path == $1.path && $0.bytes == $1.bytes
            })
        else { throw FunctionalFailure.invalid("raw saved bytes changed") }
    }

    private func requireDirectories() throws {
        try root.requireCurrent()
        for directory in directories { try directory.requireCurrent() }
    }

    private func observe(_ file: FileDefinition) throws -> FileObservation {
        var state = stat()
        guard lstat(file.file.path, &state) == 0 else {
            guard errno == ENOENT else { throw FunctionalFailure.invalid("saved file stat") }
            return FileObservation(name: file.name, path: file.file.path, bytes: nil, identity: [:])
        }
        let pinned = try FunctionalPinnedPath(
            file.file, directory: false, maximum: file.maximumBytes)
        let bytes = try pinned.read()
        var after = stat()
        guard lstat(file.file.path, &after) == 0, try pinned.read() == bytes else {
            throw FunctionalFailure.invalid("saved file current bytes")
        }
        let identity = identity(state)
        guard identity == self.identity(after) else {
            throw FunctionalFailure.invalid("saved file current identity")
        }
        return FileObservation(
            name: file.name, path: file.file.path, bytes: bytes, identity: identity)
    }

    private func identity(_ state: stat) -> [String: String] {
        [
            "device": String(state.st_dev), "inode": String(state.st_ino),
            "uid": String(state.st_uid),
            "mode": String(state.st_mode), "links": String(state.st_nlink),
            "size": String(state.st_size),
            "modifiedSeconds": String(state.st_mtimespec.tv_sec),
            "modifiedNanoseconds": String(state.st_mtimespec.tv_nsec),
            "changedSeconds": String(state.st_ctimespec.tv_sec),
            "changedNanoseconds": String(state.st_ctimespec.tv_nsec),
        ]
    }

    private func select(_ path: [String], from object: Any?) throws -> Any? {
        var value = object
        for component in path {
            guard let current = value else { return nil }
            if let dictionary = current as? [String: Any] {
                value = dictionary[component]
            } else if let array = current as? [Any] {
                guard let index = Int(component), index >= 0, String(index) == component else {
                    throw FunctionalFailure.invalid("saved array selection")
                }
                value = index < array.count ? array[index] : nil
            } else {
                throw FunctionalFailure.invalid("saved selection container")
            }
        }
        return value
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
            [
                "reader": "independent-hosted-producer", "observationID": identifier,
                "sequence": sequence, "readbackSHA256": digest as Any? ?? NSNull(),
                "expectedSHA256": expectedBytes.map(FunctionalBytes.digest) as Any? ?? NSNull(),
            ]
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
        guard bytes == initialSaved else {
            throw FunctionalFailure.invalid("source expected saved baseline")
        }
        let observation = Observation(sequence: sequence, bytes: bytes, expectedBytes: initialSaved)
        baseline = observation
        return observation
    }

    func bindLoaded(
        capabilitySHA256: String, engine: FunctionalBirth, ui: FunctionalBirth, sequence: Int
    ) throws {
        guard let baseline, loadSequence == nil, sequence > baseline.sequence,
            FunctionalBytes.hex(capabilitySHA256, length: 64), engine.pid != ui.pid
        else { throw FunctionalFailure.invalid("load baseline binding") }
        try engine.requireCurrent()
        try ui.requireCurrent()
        guard try reader() == baseline.bytes else {
            throw FunctionalFailure.invalid("construction changed persistence")
        }
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
        guard try reader() == baseline.bytes else {
            throw FunctionalFailure.invalid("saved state changed before first mutation")
        }
        firstRequestID = requestID
        return baseline.object.merging([
            "capabilitySHA256": capability, "engine": engine.contractObject,
            "ui": ui.contractObject, "beforeRequestID": requestID,
        ]) { _, new in new }
    }

    func readSaved(sequence: Int, expected: Data?) throws -> Observation {
        guard let loadSequence, firstRequestID != nil,
            sequence > (latestReadSequence ?? loadSequence),
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
