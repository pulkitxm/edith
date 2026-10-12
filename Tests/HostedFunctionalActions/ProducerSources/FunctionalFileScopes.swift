import CoreFoundation
import Darwin
import Foundation
import WorkerFixtureSupport

final class FunctionalFileScopes {
    struct Entry: Encodable, Equatable {
        let name: String
        let componentPath: String
        let present: Bool
        let bytes: Int
        let sha256: String?
    }

    private struct Immutable {
        let path: FunctionalPinnedPath
        let sha256: String
    }

    private let resolved: [WorkerFixtureResolvedFileScope]
    private let root: FunctionalPinnedPath
    private var directories: [String: FunctionalPinnedPath] = [:]
    private var immutable: [String: Immutable] = [:]

    init(resolved: [WorkerFixtureResolvedFileScope], root: FunctionalPinnedPath) throws {
        guard resolved.count <= 32, Set(resolved.map { $0.scope.name }).count == resolved.count,
            Set(resolved.map(\.path)).count == resolved.count
        else { throw FunctionalFailure.invalid("compiled resolved file scope set") }
        self.resolved = resolved
        self.root = root
        try root.requireCurrent()
        for entry in resolved {
            guard entry.path.hasPrefix(root.url.path + "/"),
                entry.path == URL(fileURLWithPath: entry.path).standardizedFileURL.path
            else { throw FunctionalFailure.invalid("compiled scope outside owned root") }
            let parent = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
            directories[parent.path] = try FunctionalPinnedPath(parent, directory: true)
            if entry.scope.kind == .directory {
                directories[entry.path] = try FunctionalPinnedPath(
                    URL(fileURLWithPath: entry.path), directory: true)
            }
        }
        _ = try snapshot(initial: true)
    }

    struct PreparationFile {
        let path: String
        let maximumBytes: Int
        let bytes: Data
    }

    static func preparationFiles(
        owner: String, root: String, session: String, policy: WorkerFixtureRolePolicy,
        bytes: Data
    ) throws -> [PreparationFile] {
        guard bytes.count <= 8_388_608, owner == policy.owner else {
            throw FunctionalFailure.invalid("literal finite preparation scope")
        }
        let object = try FunctionalBytes.object(bytes)
        try FunctionalBytes.exact(object, ["schema", "owner", "files"])
        guard try FunctionalBytes.integer(object, "schema") == 1,
            object["owner"] as? String == owner,
            let files = object["files"] as? [[String: Any]], files.count <= 256
        else {
            throw FunctionalFailure.invalid("literal finite preparation files")
        }
        func component(_ value: WorkerFixtureFileComponent) -> [String: Any] {
            switch value {
            case .literal(let name): return ["literal": name]
            case .sessionUUID(let spelling): return ["sessionUUID": spelling.rawValue]
            case .workerDefaultsPlist(let domain): return ["workerDefaultsPlist": domain.rawValue]
            case .phase: return ["phase": true]
            }
        }
        var allowed: [(root: String, components: [[String: Any]], path: String, maximum: Int)] = []
        var bindings: [(root: String, components: [[String: Any]], path: String)] = []
        for entry in try policy.resolvedOwnedPaths(root: root, session: session, phase: .initial) {
            let scope = entry.scope
            let components = scope.components.map(component)
            bindings.append((scope.root.rawValue, components, entry.path))
            for leaf in scope.immutableFiles {
                bindings.append(
                    (
                        scope.root.rawValue, components + leaf.components.map { ["literal": $0] },
                        entry.path + "/" + leaf.components.joined(separator: "/")
                    ))
            }
            for leaf in scope.mutableFiles {
                bindings.append(
                    (
                        scope.root.rawValue, components + leaf.components.map { ["literal": $0] },
                        entry.path + "/" + leaf.components.joined(separator: "/")
                    ))
            }
            if scope.kind == .file && scope.initialState == .present {
                allowed.append((scope.root.rawValue, components, entry.path, scope.maximumBytes))
            } else if scope.kind == .directory {
                for leaf in scope.immutableFiles {
                    allowed.append(
                        (
                            scope.root.rawValue,
                            components + leaf.components.map { ["literal": $0] },
                            entry.path + "/" + leaf.components.joined(separator: "/"),
                            leaf.maximumBytes
                        ))
                }
                for leaf in scope.mutableFiles where leaf.initialState == .present {
                    allowed.append(
                        (
                            scope.root.rawValue,
                            components + leaf.components.map { ["literal": $0] },
                            entry.path + "/" + leaf.components.joined(separator: "/"),
                            leaf.maximumBytes
                        ))
                }
            }
        }
        var nodes = 0
        func encode(_ value: Any, codec: String) throws -> Data {
            if codec == "json" { return try FunctionalBytes.canonical(value) }
            guard codec == "property-list",
                PropertyListSerialization.propertyList(value, isValidFor: .binary)
            else {
                throw FunctionalFailure.invalid("source preparation codec tree")
            }
            let first = try PropertyListSerialization.data(
                fromPropertyList: value, format: .binary, options: 0)
            guard
                first
                    == (try PropertyListSerialization.data(
                        fromPropertyList: value, format: .binary, options: 0))
            else {
                throw FunctionalFailure.invalid("deterministic source property list")
            }
            return first
        }
        func expand(_ value: Any, depth: Int = 0, dataAllowed: Bool) throws -> Any {
            nodes += 1
            guard depth <= 32, nodes <= 16_384 else {
                throw FunctionalFailure.invalid("source preparation tree bound")
            }
            if let object = value as? [String: Any] {
                if let binding = object["$binding"] as? String {
                    if binding == "session" {
                        try FunctionalBytes.exact(object, ["$binding"])
                        guard FunctionalBytes.uuid(session) else {
                            throw FunctionalFailure.invalid("source preparation session binding")
                        }
                        return session
                    }
                    try FunctionalBytes.exact(object, ["$binding", "root", "components"])
                    guard binding == "owned-path", let selectedRoot = object["root"] as? String,
                        let components = object["components"] as? [[String: Any]],
                        let selected = try bindings.first(where: {
                            guard $0.root == selectedRoot else { return false }
                            return try FunctionalBytes.canonical($0.components)
                                == FunctionalBytes.canonical(components)
                        })
                    else {
                        throw FunctionalFailure.invalid("source preparation ungranted path binding")
                    }
                    return selected.path
                }
                if let cell = object["$data"] as? [String: Any] {
                    try FunctionalBytes.exact(object, ["$data"])
                    guard dataAllowed, let codec = cell["codec"] as? String else {
                        throw FunctionalFailure.invalid("source preparation data cell")
                    }
                    if codec == "base64" {
                        try FunctionalBytes.exact(cell, ["codec", "bytesBase64"])
                        guard let encoded = cell["bytesBase64"] as? String,
                            let data = Data(base64Encoded: encoded),
                            data.base64EncodedString() == encoded
                        else { throw FunctionalFailure.invalid("source preparation literal data") }
                        return data
                    }
                    try FunctionalBytes.exact(cell, ["codec", "value"])
                    guard ["json", "property-list"].contains(codec), let nested = cell["value"]
                    else {
                        throw FunctionalFailure.invalid("source preparation nested data codec")
                    }
                    return try encode(
                        expand(nested, depth: depth + 1, dataAllowed: codec == "property-list"),
                        codec: codec)
                }
                guard object.keys.allSatisfy({ !$0.hasPrefix("$") }) else {
                    throw FunctionalFailure.invalid("unknown source preparation binding")
                }
                var result: [String: Any] = [:]
                for key in object.keys.sorted() {
                    result[key] = try expand(
                        object[key]!, depth: depth + 1, dataAllowed: dataAllowed)
                }
                return result
            }
            if let array = value as? [Any] {
                return try array.map { try expand($0, depth: depth + 1, dataAllowed: dataAllowed) }
            }
            guard value is String || value is NSNumber || value is NSNull else {
                throw FunctionalFailure.invalid("source preparation literal value")
            }
            return value
        }
        var paths = Set<String>()
        var total = 0
        return try files.map { file in
            let data: Data
            if file["bytesBase64"] != nil {
                try FunctionalBytes.exact(
                    file, ["root", "components", "bytesBase64", "maximumBytes"])
                guard let encoded = file["bytesBase64"] as? String,
                    let decoded = Data(base64Encoded: encoded),
                    decoded.base64EncodedString() == encoded
                else {
                    throw FunctionalFailure.invalid("source preparation canonical literal bytes")
                }
                data = decoded
            } else {
                try FunctionalBytes.exact(
                    file, ["root", "components", "codec", "value", "maximumBytes"])
                guard let codec = file["codec"] as? String,
                    ["json", "property-list"].contains(codec),
                    let value = file["value"]
                else { throw FunctionalFailure.invalid("source preparation typed codec") }
                data = try encode(
                    expand(value, dataAllowed: codec == "property-list"), codec: codec)
            }
            guard let selectedRoot = file["root"] as? String,
                let components = file["components"] as? [[String: Any]],
                let maximum = Int(exactly: try FunctionalBytes.integer(file, "maximumBytes")),
                maximum > 0,
                let selected = try allowed.first(where: { entry in
                    guard entry.root == selectedRoot else { return false }
                    return try FunctionalBytes.canonical(entry.components)
                        == FunctionalBytes.canonical(components)
                }),
                maximum <= selected.maximum, data.count <= maximum,
                paths.insert(selected.path.lowercased()).inserted,
                !["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aiff", "caf"].contains(
                    URL(fileURLWithPath: selected.path).pathExtension.lowercased())
            else {
                throw FunctionalFailure.invalid(
                    "preparation outside actual present initial file policy")
            }
            total += data.count
            guard total <= 8_388_608 else {
                throw FunctionalFailure.invalid("literal preparation aggregate bytes")
            }
            return PreparationFile(path: selected.path, maximumBytes: maximum, bytes: data)
        }
    }

    static func normalizeActualRead(_ bytes: Data, owner: String, definition: Data) throws -> Data {
        guard !bytes.isEmpty, bytes.count <= 1_048_576 else {
            throw FunctionalFailure.invalid("bounded actual original readback")
        }
        let source = try FunctionalBytes.object(definition, maximum: 262_144)
        try FunctionalBytes.exact(source, ["schema", "owner", "normalizer"])
        guard try FunctionalBytes.integer(source, "schema") == 1,
            source["owner"] as? String == owner,
            let normalizer = source["normalizer"] as? [String: Any],
            let kind = normalizer["kind"] as? String
        else {
            throw FunctionalFailure.invalid("source original readback normalizer")
        }
        let actual = try JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed)
        let normalized: Any
        if kind == "identity" {
            try FunctionalBytes.exact(normalizer, ["kind"])
            guard actual is [String: Any] || actual is [Any] else {
                throw FunctionalFailure.invalid("actual original object or array")
            }
            normalized = actual
        } else {
            try FunctionalBytes.exact(normalizer, ["kind", "fields"])
            guard kind == "select-object",
                let fields = normalizer["fields"] as? [String: [String: Any]],
                !fields.isEmpty, fields.count <= 64
            else { throw FunctionalFailure.invalid("finite source readback projection") }
            var result: [String: Any] = [:]
            for key in fields.keys.sorted() {
                guard !key.isEmpty, key.utf8.count <= 128, !key.utf8.contains(0) else {
                    throw FunctionalFailure.invalid("source readback projection key")
                }
                let field = fields[key]!
                try FunctionalBytes.exact(field, ["path", "transform"])
                guard let path = field["path"] as? [Any], path.count <= 16,
                    let transform = field["transform"] as? String
                else { throw FunctionalFailure.invalid("finite source readback selection") }
                var value = actual
                for component in path {
                    if let key = component as? String {
                        guard !key.isEmpty, key.utf8.count <= 256, !key.utf8.contains(0),
                            let object = value as? [String: Any], let selected = object[key]
                        else {
                            throw FunctionalFailure.invalid("missing actual source readback field")
                        }
                        value = selected
                    } else {
                        guard let number = component as? NSNumber,
                            CFGetTypeID(number) != CFBooleanGetTypeID(),
                            let index = Int(exactly: number.doubleValue), index >= 0,
                            let array = value as? [Any], index < array.count
                        else {
                            throw FunctionalFailure.invalid(
                                "missing actual source readback array element")
                        }
                        value = array[index]
                    }
                }
                switch transform {
                case "identity": result[key] = value
                case "sha256-string":
                    guard let string = value as? String, string.utf8.count <= 1_048_576 else {
                        throw FunctionalFailure.invalid("actual masked source readback string")
                    }
                    result[key] = ["maskedSHA256": FunctionalBytes.digest(Data(string.utf8))]
                case "base64-json":
                    guard let encoded = value as? String, let data = Data(base64Encoded: encoded),
                        data.base64EncodedString() == encoded, !data.isEmpty,
                        data.count <= 1_048_576
                    else {
                        throw FunctionalFailure.invalid("actual source readback encoded JSON")
                    }
                    result[key] = try JSONSerialization.jsonObject(
                        with: data, options: .fragmentsAllowed)
                case "base64-property-list":
                    guard let encoded = value as? String, let data = Data(base64Encoded: encoded),
                        data.base64EncodedString() == encoded, !data.isEmpty,
                        data.count <= 1_048_576
                    else {
                        throw FunctionalFailure.invalid(
                            "actual source readback encoded property list")
                    }
                    var format = PropertyListSerialization.PropertyListFormat.binary
                    let decoded = try PropertyListSerialization.propertyList(
                        from: data, format: &format)
                    guard format == .binary, JSONSerialization.isValidJSONObject(decoded) else {
                        throw FunctionalFailure.invalid(
                            "unapproved original property list data or date representation")
                    }
                    result[key] = decoded
                default: throw FunctionalFailure.invalid("uncompiled source readback transform")
                }
            }
            normalized = result
        }
        let result = try FunctionalBytes.canonical(normalized)
        guard !result.isEmpty, result.count <= 1_048_576 else {
            throw FunctionalFailure.invalid("bounded normalized actual readback")
        }
        return result
    }

    static func prepare(_ files: [PreparationFile], root: FunctionalPinnedPath) throws {
        try root.requireCurrent()
        for file in files {
            let url = URL(fileURLWithPath: file.path)
            guard url.path.hasPrefix(root.url.path + "/"), url.standardizedFileURL.path == url.path
            else { throw FunctionalFailure.invalid("source preparation path") }
            var parents: [FunctionalPinnedPath] = []
            var parent = url.deletingLastPathComponent()
            while parent.path != root.url.path {
                parents.append(try FunctionalPinnedPath(parent, directory: true))
                parent.deleteLastPathComponent()
            }
            let descriptor = open(
                file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                throw FunctionalFailure.invalid("initial synthetic source file already present")
            }
            let count = file.bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            let synced = fsync(descriptor)
            let closed = close(descriptor)
            guard count == file.bytes.count, synced == 0, closed == 0 else {
                throw FunctionalFailure.invalid("initial synthetic source file publication")
            }
            for parent in parents { try parent.requireCurrent() }
            let pinned = try FunctionalPinnedPath(
                url, directory: false, privateMode: true, maximum: file.maximumBytes)
            guard try pinned.read() == file.bytes else {
                throw FunctionalFailure.invalid("initial synthetic source file readback")
            }
        }
        try root.requireCurrent()
    }

    func requireCurrent() throws {
        try root.requireCurrent()
        for path in directories.values { try path.requireCurrent() }
        for entry in immutable.values {
            guard try FunctionalBytes.digest(entry.path.read()) == entry.sha256 else {
                throw FunctionalFailure.invalid("immutable source input changed")
            }
        }
        _ = try snapshot(initial: false)
    }

    func snapshot(initial: Bool = false) throws -> [Entry] {
        try root.requireCurrent()
        for path in directories.values { try path.requireCurrent() }
        var result: [Entry] = []
        for entry in resolved {
            let scope = entry.scope
            if scope.kind == .file {
                result.append(
                    try observe(
                        name: scope.name, path: entry.path, componentPath: "",
                        maximumBytes: scope.maximumBytes, initialState: scope.initialState,
                        allowedStates: scope.allowedStates, initial: initial,
                        immutableInput: scope.purpose == .immutableInput))
                continue
            }
            guard scope.initialState == .present, scope.allowedStates == [.present],
                let directory = directories[entry.path]
            else { throw FunctionalFailure.invalid("compiled directory state") }
            try directory.requireCurrent()
            var leaves = Set<String>()
            var expectedDirectories = Set<String>()
            for components in scope.immutableFiles.map(\.components)
                + scope.mutableFiles.map(\.components)
            {
                let leaf = components.joined(separator: "/")
                guard leaves.insert(leaf).inserted else {
                    throw FunctionalFailure.invalid("duplicate compiled leaf")
                }
                for count in 1..<components.count {
                    expectedDirectories.insert(components.prefix(count).joined(separator: "/"))
                }
            }
            let before = try inventory(
                directory, maximumEntries: scope.maximumEntries, initial: initial)
            guard before.files.isSubset(of: leaves), before.directories == expectedDirectories
            else {
                throw FunctionalFailure.invalid("unowned scope directory entry")
            }
            var total = 0
            for leaf in scope.immutableFiles {
                let componentPath = leaf.components.joined(separator: "/")
                let value = try observe(
                    name: scope.name, path: entry.path + "/" + componentPath,
                    componentPath: componentPath, maximumBytes: leaf.maximumBytes,
                    initialState: .present, allowedStates: [.present], initial: initial,
                    immutableInput: true)
                total += value.bytes
                result.append(value)
            }
            for leaf in scope.mutableFiles {
                let componentPath = leaf.components.joined(separator: "/")
                let value = try observe(
                    name: scope.name, path: entry.path + "/" + componentPath,
                    componentPath: componentPath, maximumBytes: leaf.maximumBytes,
                    initialState: leaf.initialState, allowedStates: leaf.allowedStates,
                    initial: initial, immutableInput: false)
                total += value.bytes
                result.append(value)
            }
            guard total <= scope.maximumBytes else {
                throw FunctionalFailure.invalid("scope aggregate byte bound")
            }
            try directory.requireCurrent()
            let after = try inventory(
                directory, maximumEntries: scope.maximumEntries, initial: false)
            guard before.files == after.files, before.directories == after.directories else {
                throw FunctionalFailure.invalid("scope inventory changed during read")
            }
        }
        for path in directories.values { try path.requireCurrent() }
        try root.requireCurrent()
        return result.sorted { ($0.name, $0.componentPath) < ($1.name, $1.componentPath) }
    }

    private func observe(
        name: String, path: String, componentPath: String, maximumBytes: Int,
        initialState: WorkerFixtureFilePresence, allowedStates: [WorkerFixtureFilePresence],
        initial: Bool, immutableInput: Bool
    ) throws -> Entry {
        var state = stat()
        let present = lstat(path, &state) == 0
        if !present {
            guard errno == ENOENT, allowedStates.contains(.absent),
                !initial || initialState == .absent,
                !immutableInput
            else { throw FunctionalFailure.invalid("source scope unexpectedly absent") }
            return Entry(
                name: name, componentPath: componentPath, present: false, bytes: 0, sha256: nil)
        }
        guard allowedStates.contains(.present), !initial || initialState == .present,
            state.st_mode & S_IFMT == S_IFREG, state.st_nlink == 1, state.st_uid == getuid(),
            state.st_size >= 0, state.st_size <= maximumBytes
        else { throw FunctionalFailure.invalid("source scope regular file state") }
        let opened = try FunctionalPinnedPath(
            URL(fileURLWithPath: path), directory: false, maximum: maximumBytes)
        let bytes = try opened.read()
        let digest = FunctionalBytes.digest(bytes)
        if immutableInput {
            if let pinned = immutable[path] {
                guard digest == pinned.sha256 else {
                    throw FunctionalFailure.invalid("immutable input bytes changed")
                }
                try pinned.path.requireCurrent()
            } else {
                guard initial else {
                    throw FunctionalFailure.invalid("immutable input missing initial pin")
                }
                immutable[path] = Immutable(path: opened, sha256: digest)
            }
        }
        return Entry(
            name: name, componentPath: componentPath, present: true, bytes: bytes.count,
            sha256: digest)
    }

    private func inventory(_ directory: FunctionalPinnedPath, maximumEntries: Int, initial: Bool)
        throws -> (files: Set<String>, directories: Set<String>)
    {
        var pending = [directory.url]
        var files = Set<String>()
        var directories = Set<String>()
        while let parent = pending.popLast() {
            let pin = try FunctionalPinnedPath(parent, directory: true)
            try pin.requireCurrent()
            let children = try FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil)
            guard files.count + directories.count + children.count <= maximumEntries else {
                throw FunctionalFailure.invalid("scope entry bound")
            }
            for child in children {
                guard child.path.hasPrefix(directory.url.path + "/") else {
                    throw FunctionalFailure.invalid("scope traversal outside directory")
                }
                var state = stat()
                guard lstat(child.path, &state) == 0, state.st_uid == getuid(),
                    state.st_mode & 0o022 == 0
                else {
                    throw FunctionalFailure.invalid("scope entry ownership")
                }
                let relative = String(child.path.dropFirst(directory.url.path.count + 1))
                switch state.st_mode & S_IFMT {
                case S_IFREG:
                    guard state.st_nlink == 1 else {
                        throw FunctionalFailure.invalid("scope hard link")
                    }
                    files.insert(relative)
                case S_IFDIR:
                    guard child.path == child.resolvingSymlinksInPath().path else {
                        throw FunctionalFailure.invalid("scope directory alias")
                    }
                    if let held = self.directories[child.path] {
                        try held.requireCurrent()
                    } else {
                        guard initial else {
                            throw FunctionalFailure.invalid("unheld scope ancestor")
                        }
                        self.directories[child.path] = try FunctionalPinnedPath(
                            child, directory: true)
                    }
                    directories.insert(relative)
                    pending.append(child)
                default: throw FunctionalFailure.invalid("scope nonregular entry")
                }
            }
            try pin.requireCurrent()
        }
        try directory.requireCurrent()
        return (files, directories)
    }
}
