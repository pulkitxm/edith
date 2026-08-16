import Foundation

public struct MachineItemsPayload: Codable, Equatable, Sendable {
    public var machineID: UUID
    public var paths: [String]
    public var isLocal: Bool

    public init(machineID: UUID, paths: [String], isLocal: Bool) {
        self.machineID = machineID
        self.paths = paths
        self.isLocal = isLocal
    }

    public static let typeIdentifier = "page.pulkit.edith.machine-items"

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) -> MachineItemsPayload? {
        try? JSONDecoder().decode(MachineItemsPayload.self, from: data)
    }
}

public enum DropIntent: Equatable, Sendable {
    case moveWithinMachine([String])
    case copyWithinMachine([String])
    case transferBetweenMachines(from: UUID, paths: [String])
    case uploadLocalFiles([String])

    public var paths: [String] {
        switch self {
        case let .moveWithinMachine(paths), let .copyWithinMachine(paths):
            return paths
        case let .transferBetweenMachines(_, paths):
            return paths
        case let .uploadLocalFiles(paths):
            return paths
        }
    }
}

public enum DropResolver {
    public static func intent(
        payload: MachineItemsPayload?, fileURLPaths: [String], destinationMachine: UUID,
        optionHeld: Bool
    ) -> DropIntent? {
        if let payload, !payload.paths.isEmpty {
            if payload.machineID == destinationMachine {
                return optionHeld
                    ? .copyWithinMachine(payload.paths) : .moveWithinMachine(payload.paths)
            }
            return .transferBetweenMachines(from: payload.machineID, paths: payload.paths)
        }
        guard !fileURLPaths.isEmpty else { return nil }
        return .uploadLocalFiles(fileURLPaths)
    }

    public static func isDropAllowed(paths: [String], destination: String) -> Bool {
        for path in paths {
            if path == destination { return false }
            if destination.hasPrefix(path + "/") { return false }
            if (path as NSString).deletingLastPathComponent == destination { return false }
        }
        return true
    }
}

public enum NameConflictResolution: String, Equatable, Sendable {
    case replace
    case keepBoth
    case skip
}

public enum NameFolding {
    public static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lz"]

    public static func key(_ name: String, caseInsensitive: Bool) -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        return caseInsensitive ? normalized.lowercased() : normalized
    }

    public static func split(_ name: String) -> (base: String, suffix: String) {
        let lowered = name.lowercased()
        for compound in compoundExtensions where lowered.hasSuffix(".\(compound)") {
            return (String(name.dropLast(compound.count + 1)), ".\(compound)")
        }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return (name, "") }
        return ((name as NSString).deletingPathExtension, ".\(ext)")
    }
}

public enum NameConflicts {
    public static let stagingSuffix = ".edith-replacing"

    public static func conflicting(
        names: [String], existing: [RemoteFileEntry], caseInsensitive: Bool = true
    ) -> [String] {
        let taken = Set(existing.map { NameFolding.key($0.name, caseInsensitive: caseInsensitive) })
        var seen: Set<String> = []
        return names.filter { name in
            let key = NameFolding.key(name, caseInsensitive: caseInsensitive)
            defer { seen.insert(key) }
            return taken.contains(key) || seen.contains(key)
        }
    }

    public static func uniqueName(
        for name: String, existing: [RemoteFileEntry], caseInsensitive: Bool = true
    ) -> String {
        var taken = Set(
            existing.map { NameFolding.key($0.name, caseInsensitive: caseInsensitive) })
        return claim(name, taken: &taken, caseInsensitive: caseInsensitive)
    }

    static func claim(
        _ name: String, taken: inout Set<String>, caseInsensitive: Bool
    ) -> String {
        let key = NameFolding.key(name, caseInsensitive: caseInsensitive)
        guard taken.contains(key) else {
            taken.insert(key)
            return name
        }
        let parts = NameFolding.split(name)
        var index = 2
        while true {
            let candidate = "\(parts.base) \(index)\(parts.suffix)"
            let candidateKey = NameFolding.key(candidate, caseInsensitive: caseInsensitive)
            if !taken.contains(candidateKey) {
                taken.insert(candidateKey)
                return candidate
            }
            index += 1
        }
    }

    public static func command(
        intent: DropIntent, destination: String, resolutions: [String: NameConflictResolution],
        existing: [RemoteFileEntry], caseInsensitive: Bool = true
    ) -> String? {
        var parts: [String] = []
        var taken = Set(existing.map { NameFolding.key($0.name, caseInsensitive: caseInsensitive) })
        for path in intent.paths {
            let name = (path as NSString).lastPathComponent
            let resolution = resolutions[name] ?? .keepBoth
            guard resolution != .skip else { continue }
            let targetName =
                resolution == .keepBoth
                ? claim(name, taken: &taken, caseInsensitive: caseInsensitive) : name
            let target = FileListing.join(parent: destination, name: targetName)
            let quotedSource = ShellQuote.quote(path)
            let quotedTarget = ShellQuote.quote(target)
            let verb: String
            switch intent {
            case .moveWithinMachine: verb = "mv"
            case .copyWithinMachine: verb = "cp -a"
            case .transferBetweenMachines, .uploadLocalFiles: return nil
            }
            if resolution == .replace {
                let staged = ShellQuote.quote(target + stagingSuffix)
                parts.append(
                    "\(verb) \(quotedSource) \(staged) && rm -rf \(quotedTarget)"
                        + " && mv \(staged) \(quotedTarget)")
            } else {
                parts.append("\(verb) \(quotedSource) \(quotedTarget)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

public struct FileOperationProgress: Equatable, Sendable {
    public var title: String
    public var completed: Int
    public var total: Int
    public var bytesTransferred: Int64

    public init(title: String, completed: Int = 0, total: Int = 1, bytesTransferred: Int64 = 0) {
        self.title = title
        self.completed = completed
        self.total = total
        self.bytesTransferred = bytesTransferred
    }

    public var fraction: Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 0
    }

    public var description: String {
        guard total > 1 else { return title }
        return "\(title) (\(completed) of \(total))"
    }
}

public enum BatchRename {
    public static func apply(
        names: [String], find: String, replace: String, numbering: Bool, startAt: Int = 1
    ) -> [String] {
        var results: [String] = []
        var index = startAt
        for name in names {
            var next = name
            if !find.isEmpty {
                next = next.replacingOccurrences(of: find, with: replace)
            }
            if numbering {
                let base = (next as NSString).deletingPathExtension
                let ext = (next as NSString).pathExtension
                let suffix = ext.isEmpty ? "" : ".\(ext)"
                next = "\(base) \(index)\(suffix)"
                index += 1
            }
            results.append(next)
        }
        return results
    }
}

public struct FinderUndoStep: Equatable, Sendable {
    public struct Move: Equatable, Sendable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public var label: String
    public var moves: [Move]

    public init(label: String, moves: [Move]) {
        self.label = label
        self.moves = moves
    }
}
