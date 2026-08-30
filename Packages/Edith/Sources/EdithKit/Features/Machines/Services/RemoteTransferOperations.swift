import EdithCore
import Darwin
import Foundation

public enum RemoteTransferOperation: String, CaseIterable, Sendable {
    case downloadSelection
    case transferBetweenMachines
    case uploadFile
    case copyWithinMachine
    case moveWithinMachine

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .downloadSelection:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "machines.files.download-selection"),
                summary: "Download multiple machine files.",
                cli: ["machines", "files", "get-many"], effect: .write,
                requiresPreview: true)
        case .transferBetweenMachines:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "machines.files.transfer-between-machines"),
                summary: "Transfer files between two machines.",
                cli: ["machines", "files", "transfer"], effect: .write,
                requiresPreview: true)
        case .uploadFile:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "machines.files.upload-file"),
                summary: "Upload a file to a machine.",
                cli: ["machines", "files", "put"], effect: .write,
                requiresPreview: true)
        case .copyWithinMachine:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "machines.files.copy-within-machine"),
                summary: "Copy files on a machine.",
                cli: ["machines", "files", "cp"], effect: .write,
                requiresPreview: true)
        case .moveWithinMachine:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "machines.files.move-within-machine"),
                summary: "Move files on a machine.",
                cli: ["machines", "files", "mv"], effect: .write,
                requiresPreview: true)
        }
    }
}

public struct RemoteTransferPlanItem: Equatable, Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let replacesExisting: Bool

    public init(sourcePath: String, destinationPath: String, replacesExisting: Bool) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.replacesExisting = replacesExisting
    }

    public var name: String {
        (sourcePath.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
    }
}

public struct RemoteTransferPlan: Equatable, Sendable {
    public let destination: String
    public let items: [RemoteTransferPlanItem]
    public let skipped: [String]

    public init(destination: String, items: [RemoteTransferPlanItem], skipped: [String]) {
        self.destination = destination
        self.items = items
        self.skipped = skipped
    }

    public var replacements: [RemoteTransferPlanItem] {
        items.filter(\.replacesExisting)
    }
}

public struct RemoteTransferFailure: Equatable, Sendable {
    public let sourcePath: String
    public let destination: String
    public let message: String

    public init(sourcePath: String, destination: String, message: String) {
        self.sourcePath = sourcePath
        self.destination = destination
        self.message = message
    }
}

public struct RemoteTransferOutcome: Equatable, Sendable {
    public let completed: [RemoteTransferPlanItem]
    public let failures: [RemoteTransferFailure]

    public init(
        completed: [RemoteTransferPlanItem], failures: [RemoteTransferFailure]
    ) {
        self.completed = completed
        self.failures = failures
    }
}

public enum RemoteTransferError: LocalizedError, Equatable, Sendable {
    case replacementConfirmationRequired([String])
    case destinationExists(String)
    case destinationDirectoryMissing(String)
    case unsupportedDirectory(String)
    case listingFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .replacementConfirmationRequired(paths):
            "Replacement needs confirmation for \(paths.joined(separator: ", "))."
        case let .destinationExists(path):
            "An item already exists at \(path)."
        case let .destinationDirectoryMissing(path):
            "The destination directory does not exist at \(path)."
        case let .unsupportedDirectory(path):
            "Directory transfer is not available for \(path)."
        case let .listingFailed(message):
            message
        }
    }
}

public struct RemoteTransferEndpoint: Sendable {
    public typealias IsDirectory = @Sendable (String) async throws -> Bool
    public typealias List = @Sendable (String) async throws -> [RemoteFileEntry]
    public typealias Fetch = @Sendable (String, URL) async throws -> Void
    public typealias Store = @Sendable (URL, String, Bool) async throws -> Void

    public let machineID: UUID
    public let name: String
    private let isDirectoryAction: IsDirectory
    private let listAction: List
    private let fetchAction: Fetch
    private let storeAction: Store

    public init(
        machineID: UUID, name: String,
        isDirectory: @escaping IsDirectory = { _ in false },
        list: @escaping List,
        fetch: @escaping Fetch,
        store: @escaping Store
    ) {
        self.machineID = machineID
        self.name = name
        isDirectoryAction = isDirectory
        listAction = list
        fetchAction = fetch
        storeAction = store
    }

    public func isDirectory(_ path: String) async throws -> Bool {
        try Task.checkCancellation()
        let result = try await isDirectoryAction(path)
        try Task.checkCancellation()
        return result
    }

    public func list(_ path: String) async throws -> [RemoteFileEntry] {
        try await listAction(path)
    }

    public func fetch(_ path: String, to localURL: URL) async throws {
        try await fetchAction(path, localURL)
    }

    public func store(_ localURL: URL, at path: String, replacing: Bool) async throws {
        try await storeAction(localURL, path, replacing)
    }

    public static func local(machineID: UUID, name: String) -> RemoteTransferEndpoint {
        RemoteTransferEndpoint(
            machineID: machineID, name: name,
            isDirectory: { path in
                try Task.checkCancellation()
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: path, isDirectory: &isDirectory)
                try Task.checkCancellation()
                return exists && isDirectory.boolValue
            },
            list: { path in try localEntries(path) },
            fetch: { path, destination in
                try Task.checkCancellation()
                let source = URL(fileURLWithPath: path)
                let values = try source.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory != true else {
                    throw RemoteTransferError.unsupportedDirectory(path)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            },
            store: { source, path, replacing in
                try Task.checkCancellation()
                try storeLocally(source, at: URL(fileURLWithPath: path), replacing: replacing)
            })
    }

    public static func remote(
        machine: Machine, connection: SSHConnection
    ) -> RemoteTransferEndpoint {
        RemoteTransferEndpoint(
            machineID: machine.id, name: machine.name,
            isDirectory: { path in
                try Task.checkCancellation()
                let quoted = ShellQuote.quote(path)
                let result = try await connection.run(
                    "if test -d \(quoted); then printf directory; else printf other; fi",
                    timeout: 20)
                try Task.checkCancellation()
                guard result.succeeded else {
                    let detail = result.stderrText.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    throw RemoteTransferError.listingFailed(
                        detail.isEmpty
                            ? "Could not inspect \(path) on \(machine.name)." : detail)
                }
                return result.stdoutText == "directory"
            },
            list: { path in
                let result = try await connection.run(
                    FileListing.command(path: path, showHidden: true), timeout: 45)
                guard result.succeeded else {
                    let detail = result.stderrText.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    throw RemoteTransferError.listingFailed(
                        detail.isEmpty ? "Could not read \(path) on \(machine.name)." : detail)
                }
                return FileListing.parse(output: result.stdoutText, parent: path)
            },
            fetch: { path, destination in
                try Task.checkCancellation()
                try await connection.download(remotePath: path, to: destination)
            },
            store: { source, path, replacing in
                try Task.checkCancellation()
                let values = try source.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory != true else {
                    throw RemoteTransferError.unsupportedDirectory(source.path)
                }
                let staged = path + NameConflicts.stagingSuffix + "-" + UUID().uuidString
                do {
                    try await connection.upload(localURL: source, toRemotePath: staged)
                    try Task.checkCancellation()
                    _ = try await connection.runChecked(
                        remoteStoreCommand(staged: staged, target: path, replacing: replacing),
                        timeout: 45)
                } catch {
                    await removeRemoteStage(staged, connection: connection)
                    throw error
                }
            })
    }

    private static func removeRemoteStage(_ path: String, connection: SSHConnection) async {
        _ = await Task.detached {
            try? await connection.run(
                "rm -f \(ShellQuote.quote(path))", timeout: 30)
        }.value
    }

    static func remoteStoreCommand(
        staged: String, target: String, replacing: Bool
    ) -> String {
        let source = ShellQuote.quote(staged)
        let destination = ShellQuote.quote(target)
        let nestedSource = ShellQuote.quote(
            FileListing.join(
                parent: target, name: (staged as NSString).lastPathComponent))
        let prepare =
            "edith_inode() { stat -c '%d:%i' \"$1\" 2>/dev/null"
            + " || stat -f '%d:%i' \"$1\" 2>/dev/null; }; "
            + "edith_source_inode=$(edith_inode \(source)) || exit 74; "
        let publish =
            "edith_status=0; mv -n \(source) \(destination) || edith_status=$?; "
            + "if [ \"$edith_status\" -eq 0 ]"
            + " && { [ -e \(source) ] || [ -L \(source) ]; }; then edith_status=73; fi; "
            + "if [ \"$edith_status\" -eq 0 ]; then "
            + "edith_target_inode=$(edith_inode \(destination)) || edith_status=$?; fi; "
            + "if [ \"$edith_status\" -eq 0 ]"
            + " && [ \"$edith_target_inode\" != \"$edith_source_inode\" ]; then "
            + "edith_status=73; fi; "
            + "if [ \"$edith_status\" -ne 0 ]; then "
            + "edith_nested_inode=$(edith_inode \(nestedSource)) || true; "
            + "if [ \"$edith_nested_inode\" = \"$edith_source_inode\" ]; then "
            + "rm -f \(nestedSource); fi; fi; "
        if replacing {
            let backupPath =
                target + NameConflicts.stagingSuffix + "-backup-" + UUID().uuidString
            let backup = ShellQuote.quote(backupPath)
            return
                prepare
                + "if [ -d \(destination) ] && [ ! -L \(destination) ]; then "
                + "printf '%s\\n' 'A directory cannot be replaced by a file.' >&2; exit 73; fi; "
                + "if [ -e \(destination) ] || [ -L \(destination) ]; then "
                + "mv \(destination) \(backup) || exit $?; "
                + "if [ -d \(backup) ] && [ ! -L \(backup) ]; then "
                + "if [ ! -e \(destination) ] && [ ! -L \(destination) ]; then "
                + "mv -n \(backup) \(destination) >/dev/null 2>&1 || true; fi; "
                + "printf '%s\\n' 'A directory cannot be replaced by a file.' >&2; exit 73; fi; "
                + publish
                + "if [ \"$edith_status\" -eq 0 ]; then rm -f \(backup) || true; else "
                + "if [ ! -e \(destination) ] && [ ! -L \(destination) ]; then "
                + "edith_backup_inode=$(edith_inode \(backup)) || true; "
                + "mv -n \(backup) \(destination) >/dev/null 2>&1 || true; "
                + "edith_restored_inode=$(edith_inode \(destination)) || true; "
                + "if [ \"$edith_restored_inode\" != \"$edith_backup_inode\" ]; then "
                + "printf '%s%s\\n' 'Transfer failed; original retained at ' \(backup) >&2; "
                + "fi; elif [ -e \(backup) ] || [ -L \(backup) ]; then "
                + "printf '%s%s\\n' 'Transfer failed; original retained at ' \(backup) >&2; fi; "
                + "exit \"$edith_status\"; fi; else "
                + publish
                + "if [ \"$edith_status\" -ne 0 ]; then "
                + "printf '%s\\n' 'The destination changed before publication.' >&2; "
                + "exit \"$edith_status\"; fi; fi"
        }
        return
            prepare + publish
            + "if [ \"$edith_status\" -ne 0 ]; then "
            + "printf '%s\\n' 'The destination changed before publication.' >&2; "
            + "exit \"$edith_status\"; fi"
    }

    static func withinMachinePublishCommand(
        staged: String, target: String, replacing: Bool
    ) -> String {
        let source = ShellQuote.quote(staged)
        let destination = ShellQuote.quote(target)
        let nestedSource = ShellQuote.quote(
            FileListing.join(
                parent: target, name: (staged as NSString).lastPathComponent))
        let prepare =
            "edith_inode() { stat -c '%d:%i' \"$1\" 2>/dev/null"
            + " || stat -f '%d:%i' \"$1\" 2>/dev/null; }; "
            + "edith_exists() { [ -e \"$1\" ] || [ -L \"$1\" ]; }; "
            + "edith_source_inode=$(edith_inode \(source)) || exit 74; "
        let publish =
            "edith_status=0; mv -n \(source) \(destination) || edith_status=$?; "
            + "if [ \"$edith_status\" -eq 0 ] && edith_exists \(source); then "
            + "edith_status=73; fi; "
            + "if [ \"$edith_status\" -eq 0 ]; then "
            + "edith_target_inode=$(edith_inode \(destination)) || edith_status=$?; fi; "
            + "if [ \"$edith_status\" -eq 0 ]"
            + " && [ \"$edith_target_inode\" != \"$edith_source_inode\" ]; then "
            + "edith_status=73; fi; "
            + "if [ \"$edith_status\" -ne 0 ]; then "
            + "edith_nested_inode=$(edith_inode \(nestedSource)) || true; "
            + "if [ \"$edith_nested_inode\" = \"$edith_source_inode\" ]"
            + " && ! edith_exists \(source); then "
            + "mv -n \(nestedSource) \(source) >/dev/null 2>&1 || true; fi; fi; "
        guard replacing else {
            return
                prepare + publish
                + "if [ \"$edith_status\" -ne 0 ]; then "
                + "printf '%s\\n' 'The destination changed before publication.' >&2; "
                + "exit \"$edith_status\"; fi"
        }

        let backupRootPath =
            target + NameConflicts.stagingSuffix + "-backup-" + UUID().uuidString
        let backupPayloadPath = FileListing.join(parent: backupRootPath, name: "payload")
        let backupRoot = ShellQuote.quote(backupRootPath)
        let backupPayload = ShellQuote.quote(backupPayloadPath)
        return
            prepare
            + "edith_had_target=0; "
            + "if edith_exists \(destination); then "
            + "umask 077; mkdir \(backupRoot) || exit $?; "
            + "edith_original_inode=$(edith_inode \(destination))"
            + " || { edith_status=$?; rmdir \(backupRoot) >/dev/null 2>&1 || true;"
            + " exit \"$edith_status\"; }; "
            + "mv \(destination) \(backupPayload) || { edith_status=$?; "
            + "rmdir \(backupRoot) >/dev/null 2>&1 || true; exit \"$edith_status\"; }; "
            + "edith_backup_inode=$(edith_inode \(backupPayload)) || exit 74; "
            + "if edith_exists \(destination)"
            + " || [ \"$edith_backup_inode\" != \"$edith_original_inode\" ]; then "
            + "if ! edith_exists \(destination); then "
            + "mv -n \(backupPayload) \(destination) >/dev/null 2>&1 || true; fi; "
            + "if edith_exists \(backupPayload); then "
            + "printf '%s%s\\n' 'Transfer failed; original retained at ' \(backupPayload) >&2;"
            + " fi; exit 73; fi; edith_had_target=1; fi; "
            + publish
            + "if [ \"$edith_status\" -eq 0 ]; then "
            + "if [ \"$edith_had_target\" -eq 1 ]; then rm -rf \(backupRoot) || true; fi; "
            + "else if [ \"$edith_had_target\" -eq 1 ]; then "
            + "if ! edith_exists \(destination); then "
            + "mv -n \(backupPayload) \(destination) >/dev/null 2>&1 || true; "
            + "edith_restored_inode=$(edith_inode \(destination)) || true; "
            + "if [ \"$edith_restored_inode\" = \"$edith_original_inode\" ]; then "
            + "rm -rf \(backupRoot) || true; fi; fi; "
            + "if edith_exists \(backupPayload); then "
            + "printf '%s%s\\n' 'Transfer failed; original retained at ' \(backupPayload) >&2;"
            + " fi; fi; exit \"$edith_status\"; fi"
    }

    private static func localEntries(_ path: String) throws -> [RemoteFileEntry] {
        let root = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys), options: [])
        let entries = urls.map { url -> RemoteFileEntry in
            let values = try? url.resourceValues(forKeys: keys)
            let kind: FileEntryKind =
                values?.isSymbolicLink == true
                ? .symlink : (values?.isDirectory == true ? .directory : .file)
            return RemoteFileEntry(
                name: url.lastPathComponent, path: url.path, kind: kind,
                sizeBytes: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate)
        }
        return FileListing.sorted(entries)
    }

    private static func storeLocally(
        _ source: URL, at destination: URL, replacing: Bool
    ) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard
            manager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
            parentIsDirectory.boolValue
        else {
            throw RemoteTransferError.destinationDirectoryMissing(parent.path)
        }
        let staged = parent.appendingPathComponent(
            ".\(destination.lastPathComponent)\(NameConflicts.stagingSuffix)-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: source, to: staged)
        try Task.checkCancellation()
        if itemExists(at: destination) {
            guard replacing else {
                throw RemoteTransferError.destinationExists(destination.path)
            }
            let values = try? destination.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory != true || values?.isSymbolicLink == true else {
                throw RemoteTransferError.unsupportedDirectory(destination.path)
            }
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
            return
        }
        guard
            renameatx_np(
                AT_FDCWD, staged.path, AT_FDCWD, destination.path,
                UInt32(RENAME_EXCL)) == 0
        else {
            let failure = errno
            if itemExists(at: destination) {
                throw RemoteTransferError.destinationExists(destination.path)
            }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    private static func itemExists(at url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

public enum RemoteTransferOperationExecution {
    public typealias Progress = @Sendable (_ processed: Int, _ total: Int) async -> Void

    public static func plan(
        paths: [String], destination: String, existing: [RemoteFileEntry],
        resolution: NameConflictResolution = .keepBoth,
        caseInsensitive: Bool = true
    ) -> RemoteTransferPlan {
        plan(
            paths: paths, destination: destination, existing: existing,
            resolutions: Dictionary(
                paths.map { (($0 as NSString).lastPathComponent, resolution) },
                uniquingKeysWith: { first, _ in first }),
            caseInsensitive: caseInsensitive)
    }

    public static func plan(
        paths: [String], destination: String, existing: [RemoteFileEntry],
        resolutions: [String: NameConflictResolution],
        caseInsensitive: Bool = true
    ) -> RemoteTransferPlan {
        let existingKeys = Set(
            existing.map { NameFolding.key($0.name, caseInsensitive: caseInsensitive) })
        var taken = existingKeys
        var claimedReplacements: Set<String> = []
        var suffixCursors: [String: Int] = [:]
        var items: [RemoteTransferPlanItem] = []
        var skipped: [String] = []
        items.reserveCapacity(paths.count)
        skipped.reserveCapacity(paths.count)

        func claim(_ name: String) -> String {
            let key = NameFolding.key(name, caseInsensitive: caseInsensitive)
            guard taken.contains(key) else {
                taken.insert(key)
                return name
            }
            let parts = NameFolding.split(name)
            var index = suffixCursors[key] ?? 2
            while true {
                let candidate = "\(parts.base) \(index)\(parts.suffix)"
                index += 1
                let candidateKey = NameFolding.key(
                    candidate, caseInsensitive: caseInsensitive)
                guard taken.insert(candidateKey).inserted else { continue }
                suffixCursors[key] = index
                return candidate
            }
        }

        for path in paths {
            let name = (path as NSString).lastPathComponent
            let key = NameFolding.key(name, caseInsensitive: caseInsensitive)
            let collides = taken.contains(key)
            let resolution = resolutions[name] ?? .keepBoth
            if collides, resolution == .skip {
                skipped.append(path)
                continue
            }
            let replaces =
                collides && existingKeys.contains(key) && resolution == .replace
                && claimedReplacements.insert(key).inserted
            let targetName =
                replaces
                ? name
                : claim(name)
            taken.insert(NameFolding.key(targetName, caseInsensitive: caseInsensitive))
            items.append(
                RemoteTransferPlanItem(
                    sourcePath: path,
                    destinationPath: FileListing.join(parent: destination, name: targetName),
                    replacesExisting: replaces))
        }
        return RemoteTransferPlan(destination: destination, items: items, skipped: skipped)
    }

    public static func plan(
        sourcePath: String, destinationPath: String, existing: [RemoteFileEntry],
        resolution: NameConflictResolution = .keepBoth,
        caseInsensitive: Bool = true
    ) -> RemoteTransferPlan {
        let rawParent = (destinationPath as NSString).deletingLastPathComponent
        let destination = rawParent.isEmpty ? "." : rawParent
        let name = (destinationPath as NSString).lastPathComponent
        var taken = Set(
            existing.map { NameFolding.key($0.name, caseInsensitive: caseInsensitive) })
        let collides = taken.contains(
            NameFolding.key(name, caseInsensitive: caseInsensitive))
        if collides, resolution == .skip {
            return RemoteTransferPlan(
                destination: destination, items: [], skipped: [sourcePath])
        }
        let targetName =
            collides && resolution != .replace
            ? NameConflicts.claim(
                name, taken: &taken, caseInsensitive: caseInsensitive)
            : name
        let targetPath =
            rawParent.isEmpty
            ? targetName : FileListing.join(parent: rawParent, name: targetName)
        return RemoteTransferPlan(
            destination: destination,
            items: [
                RemoteTransferPlanItem(
                    sourcePath: sourcePath, destinationPath: targetPath,
                    replacesExisting: collides && resolution == .replace)
            ], skipped: [])
    }

    public static func withinMachineCommand(
        _ plan: RemoteTransferPlan, moving: Bool,
        platform: RemoteMachinePlatform = .linux
    ) -> String? {
        guard
            plan.items.allSatisfy({ item in
                DropResolver.isDropAllowed(
                    paths: [item.sourcePath], destination: item.destinationPath)
            })
        else { return nil }
        if platform == .windows {
            return WindowsFileCommands.transfer(plan.items, moving: moving)
        }
        let commands = plan.items.map { item in
            let source = ShellQuote.quote(item.sourcePath)
            let stageRootPath =
                item.destinationPath + NameConflicts.stagingSuffix + "-" + UUID().uuidString
            let stagedPath = FileListing.join(parent: stageRootPath, name: "payload")
            let stageRoot = ShellQuote.quote(stageRootPath)
            let staged = ShellQuote.quote(stagedPath)
            let publish = RemoteTransferEndpoint.withinMachinePublishCommand(
                staged: stagedPath, target: item.destinationPath,
                replacing: item.replacesExisting)
            let success =
                moving
                ? "rm -rf \(stageRoot) || true; rm -rf \(source)"
                : "rm -rf \(stageRoot) || true"
            let failure =
                "edith_status=$?; rm -rf \(stageRoot) || true; exit \"$edith_status\""
            return
                "umask 077; mkdir \(stageRoot)"
                + " && if cp -a \(source) \(staged); then "
                + "if (\(publish)); then \(success); else \(failure); fi; "
                + "else \(failure); fi"
        }
        return commands.isEmpty ? nil : commands.joined(separator: " && ")
    }

    public static func execute(
        _ plan: RemoteTransferPlan, from source: RemoteTransferEndpoint,
        to destination: RemoteTransferEndpoint, confirmsReplacement: Bool,
        stagingRoot: URL? = nil, progress: Progress? = nil
    ) async throws -> RemoteTransferOutcome {
        let replacements = plan.replacements.map(\.destinationPath)
        guard replacements.isEmpty || confirmsReplacement else {
            throw RemoteTransferError.replacementConfirmationRequired(replacements)
        }
        try Task.checkCancellation()
        let root = stagingRoot ?? FileManager.default.temporaryDirectory
        let staging = root.appendingPathComponent(
            ".edith-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var completed: [RemoteTransferPlanItem] = []
        var failures: [RemoteTransferFailure] = []
        completed.reserveCapacity(plan.items.count)
        failures.reserveCapacity(plan.items.count)
        for (index, item) in plan.items.enumerated() {
            try Task.checkCancellation()
            let itemStaging = staging.appendingPathComponent(String(index), isDirectory: true)
            let localURL = itemStaging.appendingPathComponent("payload")
            do {
                try FileManager.default.createDirectory(
                    at: itemStaging, withIntermediateDirectories: false)
                try await source.fetch(item.sourcePath, to: localURL)
                try Task.checkCancellation()
                try await destination.store(
                    localURL, at: item.destinationPath,
                    replacing: item.replacesExisting)
                try Task.checkCancellation()
                completed.append(item)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failures.append(
                    RemoteTransferFailure(
                        sourcePath: item.sourcePath, destination: item.destinationPath,
                        message: error.localizedDescription))
            }
            try? FileManager.default.removeItem(at: itemStaging)
            await progress?(index + 1, plan.items.count)
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        return RemoteTransferOutcome(completed: completed, failures: failures)
    }
}
