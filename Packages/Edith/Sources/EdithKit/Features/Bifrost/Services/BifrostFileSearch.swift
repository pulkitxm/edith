import Foundation

public struct BifrostFile: Equatable, Sendable, Identifiable {
    public let path: String
    public let name: String
    public let kind: String
    public let size: Int
    public let created: Date?
    public let modified: Date?
    public let machine: String?

    public var id: String { (machine ?? "local") + ":" + path }

    public init(
        path: String, name: String, kind: String, size: Int, created: Date?, modified: Date?,
        machine: String? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.created = created
        self.modified = modified
        self.machine = machine
    }
}

public enum BifrostFileSearch {
    public static let executable = URL(fileURLWithPath: "/usr/bin/mdfind")
    public static let limit = 60
    public static let imageExtensions = ["png", "jpg", "jpeg", "gif", "tiff", "heic", "webp"]

    public static func arguments(query: String, scopePath: String?) -> [String] {
        var arguments: [String] = []
        if let scopePath { arguments += ["-onlyin", scopePath] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            arguments += ["kMDItemLastUsedDate >= $time.today(-7)"]
        } else {
            arguments += ["-name", trimmed]
        }
        return arguments
    }

    public static func paths(from output: String, limit: Int = BifrostFileSearch.limit) -> [String]
    {
        var found: [String] = []
        for line in output.split(separator: "\n") {
            let path = String(line)
            guard path.hasPrefix("/") else { continue }
            found.append(path)
            if found.count == limit { break }
        }
        return found
    }

    public static func describe(
        paths: [String], fileManager: FileManager = .default
    ) -> [BifrostFile] {
        var described: [BifrostFile] = []
        for path in paths {
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            let url = URL(fileURLWithPath: path)
            described.append(
                BifrostFile(
                    path: path, name: url.lastPathComponent,
                    kind: kind(for: url.pathExtension),
                    size: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
                    created: attributes?[.creationDate] as? Date,
                    modified: attributes?[.modificationDate] as? Date))
        }
        return described.sorted { first, second in
            (first.modified ?? .distantPast) > (second.modified ?? .distantPast)
        }
    }

    public static func kind(for pathExtension: String) -> String {
        let normalized = pathExtension.lowercased()
        guard !normalized.isEmpty else { return "Document" }
        if imageExtensions.contains(normalized) { return normalized.uppercased() + " image" }
        return normalized.uppercased() + " file"
    }

    public static func search(
        plan: BifrostSearchPlan,
        ripgrep: URL? = BifrostRipgrep.executable(),
        run: (URL, [String]) async -> String? = { executable, arguments in
            let result = await LocalMachineCommandExecution.run(
                executable: executable, arguments: arguments,
                commandLabel: executable.lastPathComponent, timeout: 10)
            return try? result.get()
        },
        runRemote: (String, String) async -> String? = { host, command in
            await BifrostRemoteSearch.run(machineName: host, command: command)
        }
    ) async -> [BifrostFile] {
        if let machine = plan.machine {
            guard let output = await runRemote(machine, BifrostRipgrep.remoteCommand(for: plan))
            else { return [] }
            return remote(paths: paths(from: output), machine: machine)
        }
        if let ripgrep, !plan.trimmedQuery.isEmpty || plan.kind != .everything {
            if let output = await run(ripgrep, BifrostRipgrep.arguments(for: plan)) {
                let found =
                    plan.target == .name
                    ? BifrostRipgrep.filterNames(
                        paths(from: output, limit: 5_000), query: plan.query)
                    : paths(from: output)
                if !found.isEmpty { return describe(paths: Array(found.prefix(limit))) }
            }
        }
        guard
            let output = await run(executable, arguments(query: plan.query, scopePath: plan.root))
        else { return [] }
        return describe(paths: paths(from: output))
    }

    public static func remote(paths: [String], machine: String) -> [BifrostFile] {
        paths.map { path in
            BifrostFile(
                path: path, name: (path as NSString).lastPathComponent,
                kind: kind(for: (path as NSString).pathExtension), size: 0, created: nil,
                modified: nil, machine: machine)
        }
    }

    public static func results(
        files: [BifrostFile], now: Date, query: String = ""
    ) -> [BifrostResult] {
        let group =
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Recent Files" : "Results"
        var built: [BifrostResult] = []
        for file in files {
            built.append(
                BifrostResult(
                    id: "file:" + file.id, kind: .file, title: file.name,
                    subtitle: subtitle(for: file), symbolName: "doc",
                    iconPath: file.machine == nil ? file.path : nil,
                    action: .launch(path: file.path), score: 0,
                    detail: detail(for: file, now: now), group: group))
        }
        return built
    }

    static func subtitle(for file: BifrostFile) -> String {
        let where_ = BifrostFileFormat.readablePath(file.path)
        guard let machine = file.machine else { return where_ }
        return machine + " \u{00B7} " + where_
    }

    static func detail(for file: BifrostFile, now: Date) -> BifrostDetail {
        var rows: [BifrostDetailRow] = [
            BifrostDetailRow("Name", file.name),
            BifrostDetailRow("Where", BifrostFileFormat.readablePath(file.path)),
            BifrostDetailRow("Type", file.kind),
        ]
        if let machine = file.machine { rows.append(BifrostDetailRow("Machine", machine)) }
        if file.size > 0 {
            rows.append(BifrostDetailRow("Size", BifrostFileFormat.size(file.size)))
        }
        if let created = file.created {
            rows.append(BifrostDetailRow("Created", BifrostFileFormat.moment(created, now: now)))
        }
        if let modified = file.modified {
            rows.append(BifrostDetailRow("Modified", BifrostFileFormat.moment(modified, now: now)))
        }
        let isImage =
            file.machine == nil
            && imageExtensions.contains(
                URL(fileURLWithPath: file.path).pathExtension.lowercased())
        return BifrostDetail(
            title: "Metadata", rows: rows, imagePath: isImage ? file.path : nil)
    }
}
