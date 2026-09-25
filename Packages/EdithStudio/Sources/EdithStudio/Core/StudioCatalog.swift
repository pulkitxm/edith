import Foundation

public enum StudioQuickAction: String, CaseIterable, Sendable {
    case edit
    case compress
    case convert

    public var title: String {
        switch self {
        case .edit: "Edit"
        case .compress: "Compress"
        case .convert: "Convert"
        }
    }

    public var symbolName: String {
        switch self {
        case .edit: "slider.horizontal.3"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .convert: "arrow.triangle.2.circlepath"
        }
    }
}

public enum StudioCatalog {
    public static let tools: [StudioTool] = {
        let all =
            PDFOrganizeTools.all + PDFOptimizeTools.all + PDFImageTools.all + PDFConvertTools.all
            + PDFEditTools.all + [PDFComparison.tool] + registered
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }()

    static var registered: [StudioTool] {
        StudioToolRegistry.families.flatMap { $0 }
    }

    public static func tool(_ id: String) -> StudioTool? {
        tools.first { $0.id == id }
    }

    public static func tools(for kind: StudioKind) -> [StudioTool] {
        tools.filter { $0.accepts(kind: kind) }
    }

    public static func tools(accepting urls: [URL]) -> [StudioTool] {
        guard !urls.isEmpty else { return [] }
        return tools.filter { tool in
            urls.allSatisfy(tool.accepts) && urls.count >= tool.arity.minimum
                && (tool.arity.maximum.map { urls.count <= $0 } ?? true)
        }
    }

    public static func families() -> [StudioKind] {
        var ordered: [StudioKind] = []
        for tool in tools where !ordered.contains(tool.family) { ordered.append(tool.family) }
        return ordered
    }

    public static let quickActions: [StudioKind: [StudioQuickAction: String]] = [
        .image: [.edit: "image.edit", .compress: "image.compress", .convert: "image.convert"],
        .pdf: [.edit: "pdf.edit", .compress: "pdf.compress", .convert: "pdf.to-images"],
        .video: [.edit: "video.edit", .compress: "video.compress", .convert: "video.convert"],
        .audio: [.edit: "audio.trim", .compress: "audio.compress", .convert: "audio.convert"],
        .document: [.convert: "document.to-pdf", .compress: "files.zip"],
        .presentation: [.convert: "document.to-pdf", .compress: "files.zip"],
        .spreadsheet: [.convert: "document.to-pdf", .compress: "files.zip"],
        .archive: [.convert: "files.unzip"],
        .other: [.compress: "files.zip"],
    ]

    public static func quickTool(_ action: StudioQuickAction, for kind: StudioKind) -> StudioTool? {
        quickActions[kind]?[action].flatMap(tool)
    }

    public static let popularity: [String] = [
        "pdf.compress", "pdf.edit", "pdf.sign", "pdf.split", "pdf.merge", "pdf.protect",
        "pdf.organize", "pdf.to-word", "pdf.to-images", "pdf.page-numbers", "pdf.watermark",
        "pdf.redact", "pdf.ocr", "pdf.rotate", "image.edit", "image.compress", "image.convert",
        "image.resize", "image.remove-background", "image.crop", "image.watermark",
        "pdf.from-images", "video.edit", "video.compress", "video.convert", "video.trim",
        "video.to-gif", "video.extract-audio", "audio.convert", "audio.trim", "audio.compress",
        "document.to-pdf", "files.zip", "files.unzip", "ai.summarize",
    ]

    public static func ranked(_ tools: [StudioTool]) -> [StudioTool] {
        let order = Dictionary(uniqueKeysWithValues: popularity.enumerated().map { ($1, $0) })
        return tools.enumerated().sorted { left, right in
            let a = order[left.element.id] ?? popularity.count + left.offset
            let b = order[right.element.id] ?? popularity.count + right.offset
            return a < b
        }.map(\.element)
    }
}

enum StudioToolRegistry {
    static var families: [[StudioTool]] {
        [
            ImageTools.all, VideoTools.all, AudioTools.all, DocumentTools.all, FileTools.all,
            IntelligenceTools.all,
        ]
    }
}
