import Foundation

public enum StudioToolGroup: String, CaseIterable, Codable, Sendable {
    case organize
    case optimize
    case convert
    case edit
    case security
    case intelligence
    case create

    public var title: String {
        switch self {
        case .organize: "Organize"
        case .optimize: "Optimize"
        case .convert: "Convert"
        case .edit: "Edit"
        case .security: "Security"
        case .intelligence: "Intelligence"
        case .create: "Create"
        }
    }
}

public enum StudioArity: Hashable, Sendable {
    case each
    case combine(minimum: Int, maximum: Int?)
    case none

    public var minimum: Int {
        switch self {
        case .each: 1
        case let .combine(minimum, _): minimum
        case .none: 0
        }
    }

    public var maximum: Int? {
        switch self {
        case .each: nil
        case let .combine(_, maximum): maximum
        case .none: 0
        }
    }
}

public enum StudioProduct: Hashable, Sendable {
    case same
    case kind(StudioKind)
    case report

    public func kind(for input: StudioKind) -> StudioKind? {
        switch self {
        case .same: input
        case let .kind(kind): kind
        case .report: nil
        }
    }
}

public enum StudioEngine: String, CaseIterable, Codable, Sendable {
    case ffmpeg
    case qpdf

    public var title: String {
        switch self {
        case .ffmpeg: "FFmpeg"
        case .qpdf: "qpdf"
        }
    }

    public var homebrewFormula: String { rawValue }
}

public enum StudioRequirement: Hashable, Sendable {
    case engine(StudioEngine)
    case appleIntelligence
    case translation

    public var title: String {
        switch self {
        case let .engine(engine): engine.title
        case .appleIntelligence: "Apple Intelligence"
        case .translation: "Translation languages"
        }
    }
}

public enum StudioEditorKind: String, Codable, Hashable, Sendable {
    case image
    case pdf
    case video
}

public enum StudioPDFEditorMode: String, Codable, Hashable, Sendable, CaseIterable {
    case organize
    case annotate
    case sign
    case redact
    case forms
    case crop
}

public enum StudioToolStyle: Hashable, Sendable {
    case run
    case editor(StudioEditorKind, pdfMode: StudioPDFEditorMode?)
    case compare
}

public struct StudioTool: Identifiable, Sendable {
    public typealias Perform = @Sendable (StudioRun) async throws -> [URL]

    public let id: String
    public let title: String
    public let summary: String
    public let symbolName: String
    public let group: StudioToolGroup
    public let inputs: Set<StudioKind>
    public let extraExtensions: Set<String>
    public let excludedExtensions: Set<String>
    public let arity: StudioArity
    public let produces: StudioProduct
    public let options: [StudioOption]
    public let requirements: [StudioRequirement]
    public let style: StudioToolStyle
    public let keywords: [String]
    public let groupsOutputs: Bool
    public let actionTitle: String
    public let family: StudioKind
    let perform: Perform?

    public init(
        id: String, title: String, summary: String, symbol: String, group: StudioToolGroup,
        inputs: Set<StudioKind>, extraExtensions: Set<String> = [],
        excludedExtensions: Set<String> = [], arity: StudioArity = .each,
        produces: StudioProduct = .same, options: [StudioOption] = [],
        requirements: [StudioRequirement] = [], style: StudioToolStyle = .run,
        keywords: [String] = [], groupsOutputs: Bool = false, actionTitle: String? = nil,
        family: StudioKind? = nil, perform: Perform? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.symbolName = symbol
        self.group = group
        self.inputs = inputs
        self.extraExtensions = extraExtensions
        self.excludedExtensions = excludedExtensions
        self.arity = arity
        self.produces = produces
        self.options = options
        self.requirements = requirements
        self.style = style
        self.keywords = keywords
        self.groupsOutputs = groupsOutputs
        self.actionTitle = actionTitle ?? title
        self.family = family ?? Self.inferFamily(inputs)
        self.perform = perform
    }

    static func inferFamily(_ inputs: Set<StudioKind>) -> StudioKind {
        if inputs.count == 1, let only = inputs.first { return only }
        if inputs.contains(.pdf) { return .pdf }
        if inputs.contains(.video) { return .video }
        if inputs.contains(.image) { return .image }
        if inputs.contains(.audio) { return .audio }
        return inputs.contains(.document) ? .document : .other
    }

    public var defaultSettings: StudioSettings { .defaults(for: options) }

    public var isRunnable: Bool { perform != nil }

    public var needsFiles: Bool { arity != .none }

    public func accepts(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if excludedExtensions.contains(ext) { return false }
        return inputs.contains(url.studioKind) || extraExtensions.contains(ext)
    }

    public func accepts(kind: StudioKind) -> Bool { inputs.contains(kind) }

    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = ([title, summary, id] + keywords).joined(separator: " ").lowercased()
        return needle.split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}

extension StudioTool: Hashable {
    public static func == (lhs: StudioTool, rhs: StudioTool) -> Bool { lhs.id == rhs.id }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
