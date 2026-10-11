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
                directories[entry.path] = try FunctionalPinnedPath(URL(fileURLWithPath: entry.path), directory: true)
            }
        }
        _ = try snapshot(initial: true)
    }

    func requireCurrent() throws {
        try root.requireCurrent()
        for path in directories.values { try path.requireCurrent() }
        for entry in immutable.values {
            guard try FunctionalBytes.digest(entry.path.read()) == entry.sha256 else {
                throw FunctionalFailure.invalid("immutable source input changed") }
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
                result.append(try observe(name: scope.name, path: entry.path, componentPath: "",
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
            for components in scope.immutableFiles.map(\.components) + scope.mutableFiles.map(\.components) {
                let leaf = components.joined(separator: "/")
                guard leaves.insert(leaf).inserted else { throw FunctionalFailure.invalid("duplicate compiled leaf") }
                for count in 1..<components.count { expectedDirectories.insert(components.prefix(count).joined(separator: "/")) }
            }
            let before = try inventory(directory, maximumEntries: scope.maximumEntries, initial: initial)
            guard before.files.isSubset(of: leaves), before.directories == expectedDirectories else {
                throw FunctionalFailure.invalid("unowned scope directory entry") }
            var total = 0
            for leaf in scope.immutableFiles {
                let componentPath = leaf.components.joined(separator: "/")
                let value = try observe(name: scope.name, path: entry.path + "/" + componentPath,
                    componentPath: componentPath, maximumBytes: leaf.maximumBytes,
                    initialState: .present, allowedStates: [.present], initial: initial, immutableInput: true)
                total += value.bytes
                result.append(value)
            }
            for leaf in scope.mutableFiles {
                let componentPath = leaf.components.joined(separator: "/")
                let value = try observe(name: scope.name, path: entry.path + "/" + componentPath,
                    componentPath: componentPath, maximumBytes: leaf.maximumBytes,
                    initialState: leaf.initialState, allowedStates: leaf.allowedStates,
                    initial: initial, immutableInput: false)
                total += value.bytes
                result.append(value)
            }
            guard total <= scope.maximumBytes else { throw FunctionalFailure.invalid("scope aggregate byte bound") }
            try directory.requireCurrent()
            let after = try inventory(directory, maximumEntries: scope.maximumEntries, initial: false)
            guard before.files == after.files, before.directories == after.directories else {
                throw FunctionalFailure.invalid("scope inventory changed during read") }
        }
        for path in directories.values { try path.requireCurrent() }
        try root.requireCurrent()
        return result.sorted { ($0.name, $0.componentPath) < ($1.name, $1.componentPath) }
    }

    private func observe(name: String, path: String, componentPath: String, maximumBytes: Int,
        initialState: WorkerFixtureFilePresence, allowedStates: [WorkerFixtureFilePresence],
        initial: Bool, immutableInput: Bool) throws -> Entry
    {
        var state = stat()
        let present = lstat(path, &state) == 0
        if !present {
            guard errno == ENOENT, allowedStates.contains(.absent), !initial || initialState == .absent,
                !immutableInput
            else { throw FunctionalFailure.invalid("source scope unexpectedly absent") }
            return Entry(name: name, componentPath: componentPath, present: false, bytes: 0, sha256: nil)
        }
        guard allowedStates.contains(.present), !initial || initialState == .present,
            state.st_mode & S_IFMT == S_IFREG, state.st_nlink == 1, state.st_uid == getuid(),
            state.st_size >= 0, state.st_size <= maximumBytes
        else { throw FunctionalFailure.invalid("source scope regular file state") }
        let opened = try FunctionalPinnedPath(URL(fileURLWithPath: path), directory: false, maximum: maximumBytes)
        let bytes = try opened.read()
        let digest = FunctionalBytes.digest(bytes)
        if immutableInput {
            if let pinned = immutable[path] {
                guard digest == pinned.sha256 else { throw FunctionalFailure.invalid("immutable input bytes changed") }
                try pinned.path.requireCurrent()
            } else {
                guard initial else { throw FunctionalFailure.invalid("immutable input missing initial pin") }
                immutable[path] = Immutable(path: opened, sha256: digest)
            }
        }
        return Entry(name: name, componentPath: componentPath, present: true, bytes: bytes.count, sha256: digest)
    }

    private func inventory(_ directory: FunctionalPinnedPath, maximumEntries: Int, initial: Bool) throws -> (files: Set<String>, directories: Set<String>) {
        var pending = [directory.url]
        var files = Set<String>()
        var directories = Set<String>()
        while let parent = pending.popLast() {
            let pin = try FunctionalPinnedPath(parent, directory: true)
            try pin.requireCurrent()
            let children = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            guard files.count + directories.count + children.count <= maximumEntries else {
                throw FunctionalFailure.invalid("scope entry bound") }
            for child in children {
                guard child.path.hasPrefix(directory.url.path + "/") else {
                    throw FunctionalFailure.invalid("scope traversal outside directory") }
                var state = stat()
                guard lstat(child.path, &state) == 0, state.st_uid == getuid(), state.st_mode & 0o022 == 0 else {
                    throw FunctionalFailure.invalid("scope entry ownership") }
                let relative = String(child.path.dropFirst(directory.url.path.count + 1))
                switch state.st_mode & S_IFMT {
                case S_IFREG:
                    guard state.st_nlink == 1 else { throw FunctionalFailure.invalid("scope hard link") }
                    files.insert(relative)
                case S_IFDIR:
                    guard child.path == child.resolvingSymlinksInPath().path else { throw FunctionalFailure.invalid("scope directory alias") }
                    if let held = self.directories[child.path] { try held.requireCurrent() }
                    else {
                        guard initial else { throw FunctionalFailure.invalid("unheld scope ancestor") }
                        self.directories[child.path] = try FunctionalPinnedPath(child, directory: true)
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
