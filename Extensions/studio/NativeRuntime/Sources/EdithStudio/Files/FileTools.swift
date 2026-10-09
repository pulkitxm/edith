import Foundation
import ZIPFoundation

enum FileTools {
    static var all: [StudioTool] { [zip, unzip, tar] }

    static let anyKind = Set(StudioKind.allCases)

    static let zip = StudioTool(
        id: "files.zip", title: "Compress to ZIP",
        summary: "Bundle files and folders into one ZIP archive that opens anywhere.",
        symbol: "doc.zipper", group: .optimize, inputs: anyKind,
        arity: .combine(minimum: 1, maximum: nil), produces: .kind(.archive),
        options: [
            .choice(
                "method", "Compression",
                [
                    StudioChoice("deflate", "Compressed"),
                    StudioChoice("store", "Stored, no compression"),
                ],
                default: "deflate", help: "Stored is fastest for files that are already compressed."
            ),
            .text("name", "Archive name", placeholder: "Archive", default: ""),
        ],
        keywords: ["zip", "compress", "archive", "bundle", "folder"], actionTitle: "Compress",
        family: .archive
    ) { run in
        let name = archiveName(run)
        let output = run.output(named: name + ".zip")
        let method: CompressionMethod = run.settings.text("method") == "store" ? .none : .deflate
        try Zipper.zip(run.inputs, to: output, method: method) { run.progress($0) }
        return [output]
    }

    static let unzip = StudioTool(
        id: "files.unzip", title: "Extract archive",
        summary: "Open ZIP, TAR, GZ, BZ2, XZ, 7Z, RAR and other archives into a folder.",
        symbol: "archivebox", group: .convert, inputs: [.archive], produces: .kind(.other),
        keywords: ["unzip", "decompress", "extract", "open", "untar", "rar", "7z"],
        actionTitle: "Extract", family: .archive
    ) { run in
        let folder = try run.scratch("extract").appendingPathComponent(
            run.input.studioStem, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        run.status("Extracting \(run.input.lastPathComponent)")
        try await Extractor.extract(run.input, into: folder) { run.progress($0) }
        let items = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent != ".DS_Store" }
        guard !items.isEmpty else {
            throw StudioError.nothingToDo("\(run.input.lastPathComponent) is empty.")
        }
        let result = items.count == 1 ? items[0] : folder
        let destination = run.output(named: result.lastPathComponent)
        try FileManager.default.moveItem(at: result, to: destination)
        let count = Extractor.count(destination)
        run.note("Extracted \(count) item\(count == 1 ? "" : "s").")
        return [destination]
    }

    static let tar = StudioTool(
        id: "files.tar", title: "Create TAR archive",
        summary: "Pack files into a .tar.gz or .tar.xz archive for Unix and Linux systems.",
        symbol: "shippingbox", group: .optimize, inputs: anyKind,
        arity: .combine(minimum: 1, maximum: nil), produces: .kind(.archive),
        options: [
            .choice(
                "format", "Format",
                [
                    StudioChoice("gz", "tar.gz"), StudioChoice("xz", "tar.xz"),
                    StudioChoice("tar", "tar, uncompressed"),
                ], default: "gz"),
            .text("name", "Archive name", placeholder: "Archive", default: ""),
        ],
        keywords: ["tar", "gzip", "tgz", "xz", "linux", "archive"], actionTitle: "Create archive",
        family: .archive
    ) { run in
        let format = run.settings.text("format")
        let ext = format == "tar" ? "tar" : "tar." + format
        let output = run.output(named: archiveName(run) + "." + ext)
        var arguments = [
            "--no-xattrs", "--no-mac-metadata", "--no-acls", "--no-fflags",
            format == "gz" ? "-czf" : format == "xz" ? "-cJf" : "-cf", output.path,
        ]
        for input in run.inputs {
            let name = input.lastPathComponent
            arguments += [
                "-C", input.deletingLastPathComponent().path,
                name.hasPrefix("-") ? "./" + name : name,
            ]
        }
        let result = try await StudioProcess.run(
            URL(fileURLWithPath: "/usr/bin/tar"), arguments, timeout: 3600)
        guard result.status == 0 else {
            throw StudioError.failed(
                "tar could not create the archive: \(result.errorTail.suffix(300))")
        }
        return [output]
    }

    static func archiveName(_ run: StudioRun) -> String {
        let custom = run.settings.trimmed("name")
        if !custom.isEmpty { return StudioNaming.safeStem(custom) }
        if run.inputs.count == 1 {
            let stem = run.inputs[0].studioStem
            return stem.isEmpty ? run.inputs[0].lastPathComponent : stem
        }
        return "Archive"
    }
}

enum Zipper {
    static func zip(
        _ inputs: [URL], to output: URL, method: CompressionMethod, progress: (Double) -> Void
    ) throws {
        let fileManager = FileManager.default
        let archive = try Archive(url: output, accessMode: .create)
        var entries: [(path: String, url: URL)] = []
        var used = Set<String>()
        for input in inputs {
            var root = input.lastPathComponent
            var suffix = 2
            while used.contains(root.lowercased()) {
                root =
                    input.deletingPathExtension().lastPathComponent + " \(suffix)"
                    + (input.pathExtension.isEmpty ? "" : "." + input.pathExtension)
                suffix += 1
            }
            used.insert(root.lowercased())
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
                throw StudioError.unreadable(input.lastPathComponent)
            }
            entries.append((root, input))
            guard isDirectory.boolValue,
                let enumerator = fileManager.enumerator(
                    at: input, includingPropertiesForKeys: [.isDirectoryKey])
            else { continue }
            let base = input.standardizedFileURL.path
            for case let item as URL in enumerator where item.lastPathComponent != ".DS_Store" {
                let relative = String(item.standardizedFileURL.path.dropFirst(base.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                entries.append((root + "/" + relative, item))
            }
        }
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            var isDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: entry.url.path, isDirectory: &isDirectory)
            let link = (try? entry.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                .isSymbolicLink
            if isDirectory.boolValue, link != true {
                try archive.addEntry(
                    with: entry.path + "/", type: .directory, uncompressedSize: Int64(0),
                    provider: { _, _ in Data() })
            } else {
                try archive.addEntry(
                    with: entry.path, fileURL: entry.url, compressionMethod: method)
            }
            progress(Double(index + 1) / Double(entries.count))
        }
    }
}

enum Extractor {
    static let tarExtensions: Set<String> = [
        "tar", "tgz", "tbz", "tbz2", "txz", "7z", "rar", "cpio", "xar", "iso",
    ]

    static func extract(_ archive: URL, into folder: URL, progress: (Double) -> Void) async throws {
        let name = archive.lastPathComponent.lowercased()
        let ext = archive.pathExtension.lowercased()
        if ext == "zip" {
            try unzip(archive, into: folder, progress: progress)
        } else if tarExtensions.contains(ext) || name.hasSuffix(".tar.gz")
            || name.hasSuffix(".tar.bz2")
            || name.hasSuffix(".tar.xz")
        {
            try await untar(archive, into: folder)
        } else if ["gz", "bz2", "xz"].contains(ext) {
            try await decompressSingle(archive, into: folder)
        } else {
            try await untar(archive, into: folder)
        }
        progress(1)
    }

    static func contained(_ path: String, in folder: URL) -> URL? {
        let cleaned = path.replacingOccurrences(of: "\\", with: "/")
        guard !cleaned.hasPrefix("/"), !cleaned.isEmpty else { return nil }
        let target = folder.appendingPathComponent(cleaned).standardizedFileURL
        let base = folder.standardizedFileURL.path
        guard target.path == base || target.path.hasPrefix(base + "/") else { return nil }
        return target
    }

    static func unzip(_ url: URL, into folder: URL, progress: (Double) -> Void) throws {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        if encrypted(url) {
            throw StudioError.failed(
                "\(url.lastPathComponent) is password protected. Encrypted ZIP files cannot be extracted here."
            )
        }
        let entries = Array(archive)
        func name(_ entry: Entry) -> String {
            let utf8 = entry.path(using: .utf8)
            return utf8.isEmpty ? entry.path : utf8
        }
        let names = Set(entries.map(name))
        for entry in entries {
            guard contained(name(entry), in: folder) != nil else {
                throw StudioError.failed(
                    "\(url.lastPathComponent) contains an unsafe path (\(name(entry))) and was not extracted."
                )
            }
        }
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let path = name(entry)
            guard let target = contained(path, in: folder) else { continue }
            let leaf = target.lastPathComponent
            let sibling = (path as NSString).deletingLastPathComponent
            let original = (sibling as NSString).appendingPathComponent(String(leaf.dropFirst(2)))
            if path.hasPrefix("__MACOSX/") || leaf == ".DS_Store"
                || (leaf.hasPrefix("._")
                    && (names.contains(original) || names.contains(original + "/")))
            {
                continue
            }
            switch entry.type {
            case .directory:
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: true)
            case .file:
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                do {
                    _ = try archive.extract(entry, to: target)
                } catch {
                    throw StudioError.failed(
                        "\(entry.path) could not be extracted. Encrypted ZIP files are not supported."
                    )
                }
            case .symlink:
                continue
            }
            progress(Double(index + 1) / Double(max(entries.count, 1)))
        }
    }

    static func encrypted(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 22 else {
            return false
        }
        let bytes = [UInt8](data.suffix(min(data.count, 65_557)))
        guard
            let end = stride(from: bytes.count - 22, through: 0, by: -1).first(where: {
                bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 0x05
                    && bytes[$0 + 3] == 0x06
            })
        else { return false }
        func value(_ offset: Int, _ size: Int, in source: [UInt8]) -> Int {
            (0..<size).reduce(0) { $0 | Int(source[offset + $1]) << (8 * $1) }
        }
        let count = value(end + 10, 2, in: bytes)
        var offset = value(end + 16, 4, in: bytes)
        guard offset != 0xFFFF_FFFF else { return false }
        for _ in 0..<count {
            guard offset + 46 <= data.count else { return false }
            let header = [UInt8](data[offset..<(offset + 46)])
            guard value(0, 4, in: header) == 0x0201_4B50 else { return false }
            if value(8, 2, in: header) & 1 == 1 { return true }
            offset +=
                46 + value(28, 2, in: header) + value(30, 2, in: header) + value(32, 2, in: header)
        }
        return false
    }

    static func untar(_ archive: URL, into folder: URL) async throws {
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        let listing = try await StudioProcess.run(tar, ["-tf", archive.path], timeout: 600)
        guard listing.status == 0 else {
            throw StudioError.unreadable(archive.lastPathComponent)
        }
        for line in listing.output.split(separator: "\n") {
            let path = String(line)
            if contained(path, in: folder) == nil || path.split(separator: "/").contains("..") {
                throw StudioError.failed(
                    "\(archive.lastPathComponent) contains an unsafe path (\(path)) and was not extracted."
                )
            }
        }
        let result = try await StudioProcess.run(
            tar, ["-xf", archive.path, "-C", folder.path], timeout: 3600)
        guard result.status == 0 else {
            throw StudioError.failed(
                "\(archive.lastPathComponent) could not be extracted: \(result.errorTail.suffix(300))"
            )
        }
    }

    static func decompressSingle(_ archive: URL, into folder: URL) async throws {
        let ext = archive.pathExtension.lowercased()
        let tools = ["gz": "/usr/bin/gzip", "bz2": "/usr/bin/bzip2", "xz": "/usr/bin/xz"]
        guard let path = tools[ext], FileManager.default.isExecutableFile(atPath: path) else {
            throw StudioError.unavailable("This Mac cannot open .\(ext) files without extra tools.")
        }
        let output = folder.appendingPathComponent(
            archive.deletingPathExtension().lastPathComponent)
        let result = try await StudioProcess.run(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "\"$0\" -dc \"$1\" > \"$2\"", path, archive.path, output.path], timeout: 3600)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw StudioError.failed(
                "\(archive.lastPathComponent) could not be decompressed: \(result.errorTail.suffix(300))"
            )
        }
    }

    static func count(_ url: URL) -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return 1 }
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var total = 0
        while enumerator?.nextObject() != nil { total += 1 }
        return total
    }
}
