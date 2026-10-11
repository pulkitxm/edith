import Foundation

public struct WorkerFixturePresentationScope: Equatable, Sendable {
    public let location: String
    public let section: String

    public init(location: String, section: String) throws {
        guard ["main", "settings"].contains(location),
            WorkerFixtureUIContract.owners.contains(section)
                || (location == "settings"
                    && ["general", "appearance", "extensions", "extension"].contains(section))
        else { throw WorkerFixtureError.invalid }
        self.location = location; self.section = section
    }
}

public struct WorkerFixtureInputScope: Equatable, Sendable {
    public let name: String
    public let maximumBytes: Int

    public init(name: String, maximumBytes: Int) throws {
        guard WorkerFixtureRolePolicy.token(name), maximumBytes > 0, maximumBytes <= 268_435_456
        else { throw WorkerFixtureError.invalid }
        self.name = name; self.maximumBytes = maximumBytes
    }
}

public enum WorkerFixtureFileKind: String, Sendable { case file, directory }
public enum WorkerFixtureFilePurpose: String, Sendable {
    case immutableInput = "immutable-input"
    case mutableState = "mutable-state"
    case initiallyAbsentOutput = "initially-absent-output"
}
public enum WorkerFixtureFileRoot: String, Sendable {
    case ownerHome = "owner-home", ownerData = "owner-data"
    case ownerInputs = "owner-inputs", ownerOutputs = "owner-outputs"
}
public enum WorkerFixtureUUIDSpelling: String, Sendable { case lowercase, uppercase }
public enum WorkerFixtureFilePhase: String, Sendable { case initial, updated, reinstalled }
public enum WorkerFixtureFilePresence: String, Hashable, Sendable { case present, absent }

public enum WorkerFixtureFileComponent: Equatable, Sendable {
    case literal(String)
    case sessionUUID(WorkerFixtureUUIDSpelling)
    case phase
}

public struct WorkerFixtureImmutableFileScope: Equatable, Sendable {
    public let components: [String]
    public let maximumBytes: Int

    public init(components: [String], maximumBytes: Int) throws {
        guard WorkerFixtureFileScope.relative(components),
            maximumBytes > 0, maximumBytes <= 268_435_456
        else { throw WorkerFixtureError.invalid }
        self.components = components; self.maximumBytes = maximumBytes
    }
}

public struct WorkerFixtureMutableFileScope: Equatable, Sendable {
    public let components: [String]
    public let maximumBytes: Int
    public let initialState: WorkerFixtureFilePresence
    public let allowedStates: [WorkerFixtureFilePresence]

    public init(
        components: [String], maximumBytes: Int, initialState: WorkerFixtureFilePresence,
        allowedStates: [WorkerFixtureFilePresence]
    ) throws {
        guard WorkerFixtureFileScope.relative(components),
            maximumBytes > 0, maximumBytes <= 268_435_456
        else { throw WorkerFixtureError.invalid }
        try WorkerFixtureFileScope.validateStates(initialState, allowedStates)
        self.components = components; self.maximumBytes = maximumBytes
        self.initialState = initialState; self.allowedStates = allowedStates
    }
}

public struct WorkerFixtureFileScope: Equatable, Sendable {
    public let name: String
    public let kind: WorkerFixtureFileKind
    public let purpose: WorkerFixtureFilePurpose
    public let root: WorkerFixtureFileRoot
    public let components: [WorkerFixtureFileComponent]
    public let maximumBytes: Int
    public let maximumEntries: Int
    public let initialState: WorkerFixtureFilePresence
    public let allowedStates: [WorkerFixtureFilePresence]
    public let immutableFiles: [WorkerFixtureImmutableFileScope]
    public let mutableFiles: [WorkerFixtureMutableFileScope]

    public init(
        name: String, kind: WorkerFixtureFileKind, purpose: WorkerFixtureFilePurpose,
        root: WorkerFixtureFileRoot, components: [WorkerFixtureFileComponent],
        maximumBytes: Int, maximumEntries: Int, initialState: WorkerFixtureFilePresence,
        allowedStates: [WorkerFixtureFilePresence],
        immutableFiles: [WorkerFixtureImmutableFileScope],
        mutableFiles: [WorkerFixtureMutableFileScope]
    ) throws {
        guard WorkerFixtureRolePolicy.token(name),
            !components.isEmpty, components.count <= 32,
            maximumBytes >= 0, maximumBytes <= 268_435_456,
            maximumEntries >= 0, maximumEntries <= 4096,
            components.allSatisfy({
                if case .literal(let value) = $0 { return Self.component(value) }
                return true
            }),
            components.filter({
                if case .phase = $0 { return true }; return false
            }).count <= 1,
            components.filter({
                if case .sessionUUID = $0 { return true }; return false
            }).count <= 1
        else { throw WorkerFixtureError.invalid }
        try Self.validateStates(initialState, allowedStates)
        if kind == .file {
            guard maximumBytes > 0, maximumEntries == 1,
                immutableFiles.isEmpty, mutableFiles.isEmpty
            else { throw WorkerFixtureError.invalid }
        } else {
            guard initialState == .present, allowedStates == [.present] else {
                throw WorkerFixtureError.invalid
            }
        }
        switch purpose {
        case .immutableInput:
            guard root != .ownerOutputs, initialState == .present,
                allowedStates == [.present], mutableFiles.isEmpty
            else { throw WorkerFixtureError.invalid }
        case .mutableState:
            guard root != .ownerInputs, immutableFiles.isEmpty else {
                throw WorkerFixtureError.invalid
            }
        case .initiallyAbsentOutput:
            guard root == .ownerOutputs, kind == .file, initialState == .absent,
                Set(allowedStates) == [.absent, .present]
            else { throw WorkerFixtureError.invalid }
        }
        if kind == .directory {
            let entries =
                immutableFiles.map { ($0.components, $0.maximumBytes) }
                + mutableFiles.map { ($0.components, $0.maximumBytes) }
            try Self.validateInventory(entries, bytes: maximumBytes, count: maximumEntries)
        }
        self.name = name; self.kind = kind; self.purpose = purpose; self.root = root
        self.components = components; self.maximumBytes = maximumBytes
        self.maximumEntries = maximumEntries; self.initialState = initialState
        self.allowedStates = allowedStates; self.immutableFiles = immutableFiles
        self.mutableFiles = mutableFiles
    }

    static func component(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && ![".", ".."].contains(value)
            && !value.contains("/") && !value.contains("\\")
            && value.utf8.allSatisfy { $0 >= 32 && $0 < 127 }
    }

    static func relative(_ components: [String]) -> Bool {
        !components.isEmpty && components.count <= 32
            && components.allSatisfy(component)
            && components.joined(separator: "/").utf8.count <= 4096
    }

    static func validateStates(
        _ initial: WorkerFixtureFilePresence, _ states: [WorkerFixtureFilePresence]
    ) throws {
        guard !states.isEmpty, states.count <= 2, Set(states).count == states.count,
            states.contains(initial)
        else { throw WorkerFixtureError.invalid }
    }

    private static func validateInventory(
        _ entries: [([String], Int)], bytes: Int, count: Int
    ) throws {
        guard entries.count <= 4096 else { throw WorkerFixtureError.invalid }
        if entries.isEmpty {
            guard bytes == 0, count == 0 else { throw WorkerFixtureError.invalid }
            return
        }
        let names = entries.map { $0.0.joined(separator: "/").lowercased() }
        try validateSpellings(entries.map { $0.0.joined(separator: "/") })
        let leaves = Set(names)
        guard leaves.count == entries.count, bytes > 0, count > 0,
            entries.reduce(0, { $0 + $1.1 }) <= bytes
        else { throw WorkerFixtureError.invalid }
        var paths = leaves
        for entry in entries {
            for length in 1..<entry.0.count {
                let parent = entry.0.prefix(length).joined(separator: "/").lowercased()
                guard !leaves.contains(parent) else { throw WorkerFixtureError.invalid }
                paths.insert(parent)
            }
        }
        guard paths.count <= count else { throw WorkerFixtureError.invalid }
    }

    static func validateSpellings(_ paths: [String]) throws {
        var spellings: [String: String] = [:]
        for path in paths {
            let components = path.components(separatedBy: "/")
            for length in 1...components.count {
                let prefix = components.prefix(length).joined(separator: "/")
                let folded = prefix.lowercased()
                guard spellings[folded].map({ $0 == prefix }) ?? true else {
                    throw WorkerFixtureError.invalid
                }
                spellings[folded] = prefix
            }
        }
    }

    func path(
        owner: String, root fixtureRoot: String, session: String,
        phase: WorkerFixtureFilePhase
    ) throws -> String {
        let directory: String
        switch root {
        case .ownerHome: directory = fixtureRoot + "/" + owner + "-home"
        case .ownerData:
            directory =
                WorkerFixtureUIContract.identityRoot(root: fixtureRoot, session: session)
                + "/Data/" + owner
        case .ownerInputs: directory = fixtureRoot + "/inputs/" + owner
        case .ownerOutputs: directory = fixtureRoot + "/outputs/" + owner
        }
        let relative = components.map { component in
            switch component {
            case .literal(let value): return value
            case .sessionUUID(let spelling):
                return spelling == .lowercase ? session : session.uppercased()
            case .phase: return phase.rawValue
            }
        }.joined(separator: "/")
        let path = directory + "/" + relative
        guard WorkerFixtureUIContract.canonical(path) else { throw WorkerFixtureError.invalid }
        for components in immutableFiles.map(\.components) + mutableFiles.map(\.components) {
            guard
                WorkerFixtureUIContract.canonical(
                    path + "/" + components.joined(separator: "/"))
            else { throw WorkerFixtureError.invalid }
        }
        return path
    }
}

public struct WorkerFixtureOwnedPathClaim: Equatable, Sendable {
    public let name: String
    public let path: String
    public let kind: WorkerFixtureFileKind

    public init(name: String, path: String, kind: WorkerFixtureFileKind) {
        self.name = name; self.path = path; self.kind = kind
    }
}

public struct WorkerFixtureResolvedFileScope: Equatable, Sendable {
    public let scope: WorkerFixtureFileScope
    public let path: String

    init(scope: WorkerFixtureFileScope, path: String) {
        self.scope = scope; self.path = path
    }
}

public struct WorkerFixtureRolePolicy: Equatable, Sendable {
    public let owner: String
    public let primaryRole: WorkerFixtureRole
    public let operations: [String]
    public let presentations: [WorkerFixturePresentationScope]
    public let inputs: [WorkerFixtureInputScope]
    public let outputs: [String]
    public let fileScopes: [WorkerFixtureFileScope]
    public let manifestSHA256: String
    public let caseSHA256: String

    public init(
        owner: String, primaryRole: WorkerFixtureRole, operations: [String],
        presentations: [WorkerFixturePresentationScope], inputs: [WorkerFixtureInputScope],
        outputs: [String], fileScopes: [WorkerFixtureFileScope], manifestSHA256: String,
        caseSHA256: String
    ) throws {
        guard WorkerFixtureUIContract.owners.contains(owner),
            primaryRole == (WorkerFixtureUIContract.helperOwners.contains(owner) ? .helper : .app),
            !operations.isEmpty, operations.count <= 16,
            operations.allSatisfy(Self.token), Set(operations).count == operations.count,
            !presentations.isEmpty, presentations.count <= 8,
            presentations.allSatisfy({
                $0.section == owner
                    || ($0.location == "settings"
                        && ["general", "appearance", "extensions", "extension"].contains($0.section))
            }),
            Set(presentations.map { $0.location + "." + $0.section }).count == presentations.count,
            inputs.count <= 64, outputs.count <= 64, outputs.allSatisfy(Self.token),
            Set(inputs.map(\.name) + outputs).count == inputs.count + outputs.count,
            fileScopes.count <= 32, Set(fileScopes.map(\.name)).count == fileScopes.count,
            WorkerFixtureUIContract.hex(manifestSHA256, count: 64),
            WorkerFixtureUIContract.hex(caseSHA256, count: 64)
        else { throw WorkerFixtureError.invalid }
        self.owner = owner; self.primaryRole = primaryRole; self.operations = operations
        self.presentations = presentations; self.inputs = inputs; self.outputs = outputs
        self.fileScopes = fileScopes
        self.manifestSHA256 = manifestSHA256; self.caseSHA256 = caseSHA256
    }

    public func validateOwnedPaths(
        _ claims: [WorkerFixtureOwnedPathClaim], owner: String, root: String, session: String,
        phase: WorkerFixtureFilePhase
    ) throws -> [WorkerFixtureResolvedFileScope] {
        guard owner == self.owner, WorkerFixtureUIContract.canonical(root),
            WorkerFixtureUIContract.uuid(session),
            root.hasSuffix("/functional-fixture-" + session),
            claims.count == fileScopes.count,
            Set(claims.map(\.name)).count == claims.count,
            Set(claims.map { $0.path.lowercased() }).count == claims.count
        else { throw WorkerFixtureError.invalid }
        let values = try fileScopes.map { scope in
            let path = try scope.path(owner: owner, root: root, session: session, phase: phase)
            guard
                claims.contains(where: {
                    $0.name == scope.name && $0.path == path && $0.kind == scope.kind
                })
            else { throw WorkerFixtureError.invalid }
            return WorkerFixtureResolvedFileScope(scope: scope, path: path)
        }
        guard Set(values.map { $0.path.lowercased() }).count == values.count else {
            throw WorkerFixtureError.invalid
        }
        try WorkerFixtureFileScope.validateSpellings(values.map(\.path))
        for file in values where file.scope.kind == .file {
            guard !values.contains(where: { $0.path.hasPrefix(file.path + "/") }) else {
                throw WorkerFixtureError.invalid
            }
        }
        for directory in values where directory.scope.kind == .directory {
            for child in values
            where child.path.lowercased().hasPrefix(
                directory.path.lowercased() + "/")
            {
                guard child.path.hasPrefix(directory.path + "/"), child.scope.kind == .file,
                    child.scope.purpose == directory.scope.purpose
                else { throw WorkerFixtureError.invalid }
                let relative = String(child.path.dropFirst(directory.path.count + 1))
                if directory.scope.purpose == .immutableInput {
                    guard
                        let leaf = directory.scope.immutableFiles.first(where: {
                            $0.components.joined(separator: "/") == relative
                        }), child.scope.maximumBytes == leaf.maximumBytes,
                        child.scope.initialState == .present,
                        child.scope.allowedStates == [.present]
                    else { throw WorkerFixtureError.invalid }
                } else {
                    guard
                        let leaf = directory.scope.mutableFiles.first(where: {
                            $0.components.joined(separator: "/") == relative
                        }), child.scope.maximumBytes == leaf.maximumBytes,
                        child.scope.initialState == leaf.initialState,
                        Set(child.scope.allowedStates) == Set(leaf.allowedStates)
                    else { throw WorkerFixtureError.invalid }
                }
            }
        }
        return values
    }

    public func validateEngine(_ value: WorkerFixtureEngineContract) throws {
        guard value.owner == owner, value.role == primaryRole.rawValue,
            value.operations == operations, value.inputs.count == inputs.count,
            zip(value.inputs, inputs).allSatisfy({
                $0.name == $1.name && $0.maximumBytes == $1.maximumBytes
            }),
            value.outputs.map(\.name) == outputs
        else { throw WorkerFixtureError.invalid }
    }

    public func validateUI(_ value: WorkerFixtureUIContract) throws {
        guard value.owner == owner,
            value.rolePath == value.workerPath + "/Contents/Resources/Payload/" + owner + "/"
                + primaryRole.rawValue + ".bundle",
            presentations.contains(where: {
                $0.location == value.location && $0.section == value.section
            })
        else { throw WorkerFixtureError.invalid }
    }

    static func token(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            }
    }
}
