import AppKit
import GhosttyKit
import UniformTypeIdentifiers

public struct TerminalDropPayload: Sendable {
    public let files: [URL]
    public let temporaryFiles: Set<URL>

    public init(files: [URL], temporaryFiles: Set<URL> = []) {
        self.files = files
        self.temporaryFiles = temporaryFiles
    }

    private static let legacyFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let mediaTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, .pdf, .init("public.jpeg"), .init("com.compuserve.gif"),
        .init("public.heic"), .init("org.webmproject.webp"), .init("public.movie"),
        .init("public.mpeg-4"), .init("com.apple.quicktime-movie"), .init("public.audio"),
        .init("public.mp3"), .init("public.mpeg-4-audio"), .init("com.apple.m4a-audio"),
        .init("public.aiff-audio"), .init("com.microsoft.waveform-audio"),
    ]
    private static let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map {
        NSPasteboard.PasteboardType($0)
    }

    public static let pasteboardTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, legacyFilenames, .URL, .string] + mediaTypes + promiseTypes

    public static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        if !Set(types).isDisjoint(with: Set(pasteboardTypes)) { return true }
        return types.contains { type in
            guard let contentType = UTType(type.rawValue) else { return false }
            return supported(contentType)
        }
    }

    public static func files(from pasteboard: NSPasteboard) -> TerminalDropPayload? {
        let urls = fileURLs(from: pasteboard)
        if !urls.isEmpty { return TerminalDropPayload(files: urls, temporaryFiles: []) }
        guard let temporary = materializeMedia(from: pasteboard) else { return nil }
        return TerminalDropPayload(files: [temporary], temporaryFiles: [temporary])
    }

    @discardableResult
    @MainActor
    public static func receivePromisedFiles(
        from pasteboard: NSPasteboard,
        completion: @escaping @MainActor (TerminalDropPayload) -> Void
    ) -> Bool {
        guard
            let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
                as? [NSFilePromiseReceiver], !receivers.isEmpty
        else { return false }
        guard let destination = temporaryDirectory() else { return false }
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: destination, options: [:], operationQueue: queue
            ) { url, error in
                guard error == nil else { return }
                let payload = TerminalDropPayload(files: [url], temporaryFiles: [url])
                Task { @MainActor in completion(payload) }
            }
        }
        return true
    }

    public var shellText: String {
        files.map { GhosttyTerminalView.quote($0.path) }.joined(separator: " ")
    }

    public func removeTemporaryFiles() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
            let parent = url.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: parent)
            }
        }
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls =
            (pasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
            ?? []
        if let paths = pasteboard.propertyList(forType: legacyFilenames) as? [String] {
            urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
        }
        var seen = Set<String>()
        return urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    private static func materializeMedia(from pasteboard: NSPasteboard) -> URL? {
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                guard let contentType = UTType(type.rawValue), supported(contentType),
                    let data = item.data(forType: type), !data.isEmpty
                else { continue }
                let fileExtension =
                    contentType.preferredFilenameExtension
                    ?? fallbackExtension(
                        for: contentType)
                guard let directory = temporaryDirectory() else { return nil }
                let url = directory.appendingPathComponent("drop.\(fileExtension)")
                do {
                    try data.write(to: url, options: .atomic)
                    return url
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    return nil
                }
            }
        }
        guard let image = NSImage(pasteboard: pasteboard), let data = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: data),
            let png = bitmap.representation(using: .png, properties: [:]),
            let directory = temporaryDirectory()
        else { return nil }
        let url = directory.appendingPathComponent("drop.png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    private static func supported(_ type: UTType) -> Bool {
        type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie)
            || type.conforms(to: .audio)
    }

    private static func fallbackExtension(for type: UTType) -> String {
        if type.conforms(to: .pdf) { return "pdf" }
        if type.conforms(to: .movie) { return "mov" }
        if type.conforms(to: .audio) { return "m4a" }
        return "png"
    }

    private static func temporaryDirectory() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdithTerminalDrops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return directory
        } catch {
            return nil
        }
    }
}

extension GhosttyTerminalView {
    static let dropTypes = Set(TerminalDropPayload.pasteboardTypes)

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard TerminalDropPayload.canRead(sender.draggingPasteboard) else { return [] }
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        layer?.borderWidth = 2
        return .copy
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearDropHighlight()
    }

    public override func draggingEnded(_ sender: any NSDraggingInfo) {
        clearDropHighlight()
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        clearDropHighlight()
        window?.makeFirstResponder(self)
        if let payload = TerminalDropPayload.files(from: sender.draggingPasteboard) {
            return accept(payload)
        }
        let receivingPromises = TerminalDropPayload.receivePromisedFiles(
            from: sender.draggingPasteboard
        ) { [weak self] payload in
            _ = self?.accept(payload)
        }
        if receivingPromises { return true }
        guard let content = Self.dropped(from: sender.draggingPasteboard) else { return false }
        return insertText(content)
    }

    func accept(_ payload: TerminalDropPayload) -> Bool {
        if onDropFiles?(payload) == true { return true }
        temporaryDropFiles.formUnion(payload.temporaryFiles)
        return insertText(payload.shellText)
    }

    func clearDropHighlight() {
        layer?.borderWidth = 0
    }

    static func dropped(from pasteboard: NSPasteboard) -> String? {
        if let payload = TerminalDropPayload.files(from: pasteboard) {
            return payload.shellText
        }
        if let rawURL = pasteboard.string(forType: .URL), !rawURL.isEmpty {
            return quote(rawURL)
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return text
    }

    public static func quote(_ path: String) -> String {
        guard path.contains(where: { !$0.isLetter && !$0.isNumber && !"/._-".contains($0) })
        else {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
