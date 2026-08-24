import EdithCore
import Foundation

public enum MachineFileOperation: String, CaseIterable, Equatable, Sendable {
    case search
    case info
    case duplicate
    case undo
    case rename
    case remove = "rm"

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .search:
            descriptor("search", "Search a folder recursively.", effect: .read)
        case .info:
            descriptor("info", "Measure a file or directory.", effect: .read)
        case .duplicate:
            descriptor("duplicate", "Copy an item beside itself.", effect: .write)
        case .undo:
            descriptor("undo", "Undo the latest Finder move or rename.", effect: .write)
        case .rename:
            descriptor("rename", "Rename an item in place.", effect: .write)
        case .remove:
            descriptor(
                "rm", "Move items to Trash or delete them permanently.", effect: .destructive,
                requiresPreview: true)
        }
    }

    public var placement: MachineFileOperationPlacement {
        switch self {
        case .search:
            placement("search the folder", ["box", "/a", "x"])
        case .info:
            placement("get info on a directory", ["box", "/a"])
        case .duplicate:
            placement("duplicate a file", ["box", "/a"])
        case .undo:
            placement("undo the last move or rename", ["box"])
        case .rename:
            placement("rename a file", ["box", "/a", "b"])
        case .remove:
            placement("move files to the trash", ["box", "/a"])
        }
    }

    private func descriptor(
        _ verb: String, _ summary: String, effect: UserOperationEffect,
        requiresPreview: Bool = false
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.files.\(rawValue)"), summary: summary,
            cli: ["machines", "files", verb], effect: effect,
            requiresPreview: requiresPreview)
    }

    private func placement(
        _ action: String, _ arguments: [String]
    ) -> MachineFileOperationPlacement {
        MachineFileOperationPlacement(
            operation: self, surface: "Machine finder", action: action,
            exampleArguments: arguments)
    }
}

public struct MachineFileOperationPlacement: Equatable, Sendable {
    public let operation: MachineFileOperation
    public let surface: String
    public let action: String
    public let exampleArguments: [String]

    public init(
        operation: MachineFileOperation, surface: String, action: String,
        exampleArguments: [String]
    ) {
        self.operation = operation
        self.surface = surface
        self.action = action
        self.exampleArguments = exampleArguments
    }

    public var cli: [String] {
        operation.descriptor.cli + exampleArguments
    }
}

public struct MachineFileSearchItem: Equatable, Sendable {
    public let path: String
    public let kind: FileEntryKind?

    public init(path: String, kind: FileEntryKind? = nil) {
        self.path = path
        self.kind = kind
    }
}

public struct MachineFileRemovalPlan: Equatable, Sendable {
    public let paths: [String]
    public let permanently: Bool

    public init(paths: [String], permanently: Bool) {
        self.paths = paths
        self.permanently = permanently
    }

    public var requiresConfirmation: Bool { permanently }
}

public enum MachineFileRemovalOutcome: Equatable, Sendable {
    case preview(MachineFileRemovalPlan)
    case applied(MachineFileRemovalPlan)
}

public enum MachineFileOperationError: LocalizedError, Equatable, Sendable {
    case invalidLimit
    case invalidName
    case noPaths
    case missingDuplicateDestination
    case invalidSize(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLimit:
            "the search limit must be greater than zero"
        case .invalidName:
            "a new name must not be blank, dot, dot-dot, or contain a slash"
        case .noPaths:
            "name at least one path"
        case .missingDuplicateDestination:
            "the duplicate command did not report its destination"
        case let .invalidSize(output):
            output.isEmpty ? "the size command returned no size" : "invalid size: \(output)"
        }
    }
}

public enum MachineFileOperationExecution {
    public typealias Run = (String, TimeInterval) async -> Result<String, Error>
    public typealias LocalSearch =
        (String, String, Int) async -> Result<[MachineFileSearchItem], Error>
    public typealias Trash = ([String]) async -> Result<Void, Error>

    public static func search(
        path: String, query: String, limit: Int = 300, localSearch: LocalSearch? = nil,
        using run: Run
    ) async -> Result<[MachineFileSearchItem], Error> {
        guard limit > 0 else { return .failure(MachineFileOperationError.invalidLimit) }
        if let localSearch { return await localSearch(path, query, limit) }
        let result = await run(
            FileOperations.searchCommand(path: path, query: query, limit: limit), 120)
        return result.map { output in
            output.split(separator: "\n").map {
                MachineFileSearchItem(path: String($0))
            }
        }
    }

    public static func info(
        path: String, using run: Run
    ) async -> Result<Int64, Error> {
        let result = await run(FileOperations.directorySizeCommand(path: path), 120)
        return result.flatMap { output in
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kilobytes = Int64(trimmed) else {
                return .failure(MachineFileOperationError.invalidSize(trimmed))
            }
            return .success(kilobytes * 1024)
        }
    }

    public static func duplicate(
        path: String, destination: String? = nil, using run: Run
    ) async -> Result<String, Error> {
        let result = await run(
            FileOperations.duplicateCommand(path: path, destination: destination), 300)
        return result.flatMap { output in
            let created = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !created.isEmpty else {
                return .failure(MachineFileOperationError.missingDuplicateDestination)
            }
            return .success(created)
        }
    }

    public static func rename(
        path: String, name: String, viaTemporary: Bool = false, using run: Run
    ) async -> Result<String, Error> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RenameSelection.isValid(trimmed) else {
            return .failure(MachineFileOperationError.invalidName)
        }
        let parent = FileListing.parentPath(of: path) ?? ""
        let destination =
            parent.isEmpty ? trimmed : FileListing.join(parent: parent, name: trimmed)
        return await rename(
            path: path, destination: destination, viaTemporary: viaTemporary, using: run)
    }

    public static func rename(
        path: String, destination: String, viaTemporary: Bool = false, using run: Run
    ) async -> Result<String, Error> {
        let result = await run(
            FileOperations.renameCommand(
                path: path, to: destination, viaTemporary: viaTemporary),
            300)
        return result.map { _ in destination }
    }

    public static func remove(
        _ plan: MachineFileRemovalPlan, confirmed: Bool, trash: Trash? = nil,
        using run: Run
    ) async -> Result<MachineFileRemovalOutcome, Error> {
        guard !plan.paths.isEmpty else {
            return .failure(MachineFileOperationError.noPaths)
        }
        guard !plan.requiresConfirmation || confirmed else { return .success(.preview(plan)) }
        if !plan.permanently, let trash {
            return await trash(plan.paths).map { .applied(plan) }
        }
        let command =
            plan.permanently
            ? FileOperations.deleteCommand(paths: plan.paths)
            : FileOperations.trashCommand(paths: plan.paths)
        return await run(command, 300).map { _ in .applied(plan) }
    }

    public static func undo(
        _ step: FinderUndoStep, using run: Run
    ) async -> Result<[String], Error> {
        for move in step.moves.reversed() {
            let result = await run(
                FileOperations.renameCommand(path: move.to, to: move.from), 300)
            if case let .failure(error) = result { return .failure(error) }
        }
        return .success(step.moves.map(\.from))
    }
}
