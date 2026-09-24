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
        let collector = PromisedFileCollector(expected: receivers.count) { files in
            guard !files.isEmpty else {
                try? FileManager.default.removeItem(at: destination)
                return
            }
            completion(TerminalDropPayload(files: files, temporaryFiles: Set(files)))
        }
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: destination, options: [:], operationQueue: queue
            ) { url, error in
                let received = error == nil ? url : nil
                Task { @MainActor in collector.receive(received) }
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
            guard let media = media(in: item) else { continue }
            return write(media.data, fileExtension: media.fileExtension)
        }
        guard let image = NSImage(pasteboard: pasteboard), let png = pngData(from: image) else {
            return nil
        }
        return write(png, fileExtension: "png")
    }

    private static func media(in item: NSPasteboardItem) -> (data: Data, fileExtension: String)? {
        let candidates = item.types.compactMap { type -> (NSPasteboard.PasteboardType, UTType)? in
            guard let contentType = UTType(type.rawValue), supported(contentType) else {
                return nil
            }
            return (type, contentType)
        }
        let ordered =
            candidates.filter { agentReadable($0.1) } + candidates.filter { !agentReadable($0.1) }
        for (type, contentType) in ordered {
            guard let data = item.data(forType: type), !data.isEmpty else { continue }
            if contentType.conforms(to: .image), !agentReadable(contentType) {
                guard let image = NSImage(data: data), let png = pngData(from: image) else {
                    continue
                }
                return (png, "png")
            }
            return (
                data, contentType.preferredFilenameExtension ?? fallbackExtension(for: contentType)
            )
        }
        return nil
    }

    private static func write(_ data: Data, fileExtension: String) -> URL? {
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

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static let agentImageTypes: [UTType] = [.png, .jpeg, .gif, .webP]

    private static func agentReadable(_ type: UTType) -> Bool {
        agentImageTypes.contains { type.conforms(to: $0) }
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

@MainActor
final class PromisedFileCollector {
    private var remaining: Int
    private var files: [URL] = []
    private let finish: @MainActor ([URL]) -> Void

    init(expected: Int, finish: @escaping @MainActor ([URL]) -> Void) {
        remaining = expected
        self.finish = finish
    }

    func receive(_ url: URL?) {
        guard remaining > 0 else {
            if let url { finish([url]) }
            return
        }
        if let url { files.append(url) }
        remaining -= 1
        if remaining == 0 { finish(files) }
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
        if deliverDroppedFiles(from: sender.draggingPasteboard) { return true }
        guard let content = Self.dropped(from: sender.draggingPasteboard) else { return false }
        return insertText(content)
    }

    func deliverDroppedFiles(from pasteboard: NSPasteboard) -> Bool {
        let receivingPromises = TerminalDropPayload.receivePromisedFiles(from: pasteboard) {
            [weak self] payload in
            _ = self?.accept(payload)
        }
        if receivingPromises { return true }
        guard let payload = TerminalDropPayload.files(from: pasteboard) else { return false }
        return accept(payload)
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
