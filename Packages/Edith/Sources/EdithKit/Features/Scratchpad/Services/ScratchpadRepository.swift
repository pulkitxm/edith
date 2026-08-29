import Darwin
import Foundation

public enum ScratchpadRepository {
    public static func load(
        retention: ScratchpadRetention = .never, now: Date = Date()
    ) throws -> ScratchpadDocument {
        try withLock {
            let exists = FileManager.default.fileExists(atPath: ScratchpadPaths.documentFile.path)
            var document = try loadUnlocked(now: now)
            if !exists || document.applyRetention(retention, now: now) > 0 {
                try saveUnlocked(document)
            }
            return document
        }
    }

    public static func mutate<T>(
        retention: ScratchpadRetention = .never, now: Date = Date(),
        _ body: (inout ScratchpadDocument) throws -> T
    ) throws -> (document: ScratchpadDocument, value: T) {
        try withLock {
            var document = try loadUnlocked(now: now)
            _ = document.applyRetention(retention, now: now)
            let value = try body(&document)
            document = document.sanitized(now: now)
            try saveUnlocked(document)
            return (document, value)
        }
    }

    public static func create(
        name: String? = nil, text: String = "", now: Date = Date()
    ) throws -> ScratchpadDocument {
        try mutate(now: now) { document in
            guard document.pads.count < ScratchpadDocument.maximumPadCount else {
                throw ScratchpadError.padLimit
            }
            let proposed =
                name.map(ScratchpadNaming.sanitized) ?? ScratchpadNaming.next(in: document.pads)
            guard !proposed.isEmpty else { throw ScratchpadError.invalidName }
            let pad = ScratchpadPad(
                name: ScratchpadNaming.unique(proposed, excluding: nil, in: document.pads),
                text: text, createdAt: now, modifiedAt: text.isEmpty ? nil : now)
            document.pads.append(pad)
            document.selectedID = pad.id
            return pad
        }.document
    }

    public static func update(
        _ selector: String, text: String, now: Date = Date()
    ) throws -> ScratchpadDocument {
        try mutate(now: now) { document in
            let index = try index(of: selector, in: document)
            document.pads[index].text = text
            document.pads[index].modifiedAt = text.isEmpty ? nil : now
            document.selectedID = document.pads[index].id
        }.document
    }

    public static func rename(_ selector: String, to name: String) throws -> ScratchpadDocument {
        try mutate { document in
            let index = try index(of: selector, in: document)
            let cleaned = ScratchpadNaming.sanitized(name)
            guard !cleaned.isEmpty else { throw ScratchpadError.invalidName }
            document.pads[index].name = ScratchpadNaming.unique(
                cleaned, excluding: document.pads[index].id, in: document.pads)
            document.selectedID = document.pads[index].id
        }.document
    }

    public static func duplicate(_ selector: String, now: Date = Date()) throws
        -> ScratchpadDocument
    {
        try mutate(now: now) { document in
            guard document.pads.count < ScratchpadDocument.maximumPadCount else {
                throw ScratchpadError.padLimit
            }
            let index = try index(of: selector, in: document)
            let source = document.pads[index]
            let copy = ScratchpadPad(
                name: ScratchpadNaming.unique(
                    "\(source.name) copy", excluding: nil, in: document.pads),
                text: source.text, createdAt: now, modifiedAt: source.text.isEmpty ? nil : now)
            document.pads.insert(copy, at: index + 1)
            document.selectedID = copy.id
        }.document
    }

    public static func remove(_ selector: String) throws -> ScratchpadDocument {
        try mutate { document in
            guard document.pads.count > 1 else { throw ScratchpadError.onlyPad }
            let index = try index(of: selector, in: document)
            let removing = document.pads[index]
            document.pads.remove(at: index)
            if document.selectedID == removing.id {
                document.selectedID = document.pads[min(index, document.pads.count - 1)].id
            }
        }.document
    }

    public static func clear(_ selector: String, now: Date = Date()) throws -> ScratchpadDocument {
        try update(selector, text: "", now: now)
    }

    public static func select(_ selector: String) throws -> ScratchpadDocument {
        try mutate { document in
            let index = try index(of: selector, in: document)
            document.selectedID = document.pads[index].id
        }.document
    }

    public static func pad(_ selector: String, in document: ScratchpadDocument) throws
        -> ScratchpadPad
    {
        document.pads[try index(of: selector, in: document)]
    }

    public static func search(_ query: String, in document: ScratchpadDocument)
        -> [ScratchpadSearchResult]
    {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return document.pads.map { ScratchpadSearchResult(pad: $0, matchCount: 0) }
        }
        return document.pads.compactMap { pad in
            let nameMatches = occurrences(of: needle, in: pad.name)
            let textMatches = occurrences(of: needle, in: pad.text)
            let count = nameMatches + textMatches
            return count == 0 ? nil : ScratchpadSearchResult(pad: pad, matchCount: count)
        }
    }

    public static func copyAllText(_ pad: ScratchpadPad) throws -> String {
        guard !pad.text.isEmpty else { throw ScratchpadError.emptyPad }
        return pad.text
    }

    public static func export(_ pad: ScratchpadPad, to destination: URL) throws {
        guard !pad.text.isEmpty else { throw ScratchpadError.emptyPad }
        try Data(pad.text.utf8).write(to: destination, options: .atomic)
    }

    private static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(
            at: ScratchpadPaths.dir, withIntermediateDirectories: true)
        let descriptor = open(ScratchpadPaths.lockFile.path, O_RDONLY | O_CREAT, 0o600)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return try body() }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func loadUnlocked(now: Date) throws -> ScratchpadDocument {
        guard FileManager.default.fileExists(atPath: ScratchpadPaths.documentFile.path) else {
            return .initial(now: now)
        }
        let data = try Data(contentsOf: ScratchpadPaths.documentFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScratchpadDocument.self, from: data).sanitized(now: now)
    }

    private static func saveUnlocked(_ document: ScratchpadDocument) throws {
        try FileManager.default.createDirectory(
            at: ScratchpadPaths.dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: ScratchpadPaths.documentFile, options: .atomic)
    }

    private static func index(of selector: String, in document: ScratchpadDocument) throws -> Int {
        if let id = UUID(uuidString: selector),
            let index = document.pads.firstIndex(where: { $0.id == id })
        {
            return index
        }
        if let index = document.pads.firstIndex(where: {
            $0.name.compare(selector, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }) {
            return index
        }
        throw ScratchpadError.padNotFound(selector)
    }

    private static func occurrences(of query: String, in text: String) -> Int {
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let match = text.range(
            of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
        {
            count += 1
            range = match.upperBound..<text.endIndex
        }
        return count
    }
}
