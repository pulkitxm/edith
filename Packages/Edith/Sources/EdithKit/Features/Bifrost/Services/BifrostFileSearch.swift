import Foundation

public struct BifrostFile: Equatable, Sendable, Identifiable {
    public let path: String
    public let name: String
    public let kind: String
    public let size: Int
    public let created: Date?
    public let modified: Date?

    public var id: String { path }

    public init(
        path: String, name: String, kind: String, size: Int, created: Date?, modified: Date?
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.created = created
        self.modified = modified
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
        query: String, scopePath: String?,
        run: (URL, [String]) async -> String? = { executable, arguments in
            let result = await LocalMachineCommandExecution.run(
                executable: executable, arguments: arguments, commandLabel: "mdfind",
                timeout: 8)
            return try? result.get()
        }
    ) async -> [BifrostFile] {
        guard let output = await run(executable, arguments(query: query, scopePath: scopePath))
        else { return [] }
        return describe(paths: paths(from: output))
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
                    id: "file:" + file.path, kind: .file, title: file.name,
                    subtitle: BifrostFileFormat.readablePath(file.path),
                    symbolName: "doc", iconPath: file.path,
                    action: .launch(path: file.path), score: 0,
                    detail: detail(for: file, now: now), group: group))
        }
        return built
    }

    static func detail(for file: BifrostFile, now: Date) -> BifrostDetail {
        var rows: [BifrostDetailRow] = [
            BifrostDetailRow("Name", file.name),
            BifrostDetailRow("Where", BifrostFileFormat.readablePath(file.path)),
            BifrostDetailRow("Type", file.kind),
            BifrostDetailRow("Size", BifrostFileFormat.size(file.size)),
        ]
        if let created = file.created {
            rows.append(BifrostDetailRow("Created", BifrostFileFormat.moment(created, now: now)))
        }
        if let modified = file.modified {
            rows.append(BifrostDetailRow("Modified", BifrostFileFormat.moment(modified, now: now)))
        }
        let isImage = imageExtensions.contains(
            URL(fileURLWithPath: file.path).pathExtension.lowercased())
        return BifrostDetail(
            title: "Metadata", rows: rows, imagePath: isImage ? file.path : nil)
    }
}
