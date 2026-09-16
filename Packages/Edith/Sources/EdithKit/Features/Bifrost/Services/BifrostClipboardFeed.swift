import Foundation

public enum BifrostClipboardFeed {
    public static let imageTypes = ["png", "jpg", "jpeg", "gif", "tiff", "heic", "webp"]

    public static func kind(of entry: ClipboardEntry) -> String {
        if imageTypes.contains(entry.ext.lowercased()) { return "image" }
        if entry.types.contains(where: { $0.contains("file-url") }) { return "file" }
        let preview = entry.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if preview.hasPrefix("http://") || preview.hasPrefix("https://") { return "link" }
        return "text"
    }

    public static func title(of entry: ClipboardEntry) -> String {
        let preview = entry.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !preview.isEmpty else { return "Image" }
        let line = preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? preview
        return String(line.prefix(120))
    }

    public static func results(
        entries: [ClipboardEntry], query: String, scope: String, now: Date,
        imagePath: (ClipboardEntry) -> String? = { entry in
            imageTypes.contains(entry.ext.lowercased())
                ? ClipboardPaths.blobFile(sha256: entry.sha256, ext: entry.ext).path : nil
        }
    ) -> [BifrostResult] {
        let needle = BifrostUsageLedger.normalize(query)
        var built: [BifrostResult] = []
        for entry in ordered(entries) {
            let kind = kind(of: entry)
            guard scope == "all" || scope == kind else { continue }
            let title = title(of: entry)
            if !needle.isEmpty, !title.lowercased().contains(needle) { continue }
            built.append(
                BifrostResult(
                    id: "clip:" + entry.id, kind: .clip, title: title,
                    subtitle: entry.sourceApp ?? kind.capitalized,
                    symbolName: symbol(for: kind),
                    action: .copy(text: entry.preview ?? ""), score: 0,
                    detail: detail(
                        for: entry, kind: kind, now: now, bytes: bytes(of: entry),
                        imagePath: imagePath(entry)),
                    group: group(for: entry.lastCopiedAt, now: now)))
        }
        return built
    }

    public static func bytes(of entry: ClipboardEntry) -> Int {
        guard entry.size > 0 else { return entry.preview?.utf8.count ?? 0 }
        return entry.size
    }

    public static func group(for moment: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(moment, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(moment, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: moment)
    }

    public static func ordered(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.sorted { first, second in
            if first.pinned != second.pinned { return first.pinned }
            return first.lastCopiedAt > second.lastCopiedAt
        }
    }

    public static func symbol(for kind: String) -> String {
        switch kind {
        case "image": "photo"
        case "link": "link"
        case "file": "doc"
        default: "text.alignleft"
        }
    }

    static func detail(
        for entry: ClipboardEntry, kind: String, now: Date, bytes: Int, imagePath: String?
    ) -> BifrostDetail {
        var rows: [BifrostDetailRow] = []
        if let source = entry.sourceApp { rows.append(BifrostDetailRow("Source", source)) }
        rows.append(BifrostDetailRow("Content type", kind.capitalized))
        rows.append(BifrostDetailRow("Size", BifrostFileFormat.size(bytes)))
        rows.append(
            BifrostDetailRow("Copied", BifrostFileFormat.moment(entry.lastCopiedAt, now: now)))
        if entry.pinned { rows.append(BifrostDetailRow("Pinned", "Yes")) }
        return BifrostDetail(
            title: "Information", rows: rows, imagePath: imagePath,
            text: kind == "image" ? nil : entry.preview)
    }
}

public enum BifrostFileFormat {
    public static func size(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    public static func moment(_ moment: Date, now: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        if calendar.isDate(moment, inSameDayAs: now) {
            formatter.dateFormat = "'Today at' h:mm:ss a"
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return formatter.string(from: moment)
    }

    public static func readablePath(_ path: String, home: String = NSHomeDirectory()) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}
