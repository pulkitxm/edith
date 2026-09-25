import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public struct StudioEnvironment: Sendable {
    public var ffmpeg: URL?
    public var ffprobe: URL?
    public var qpdf: URL?
    public var temporaryRoot: URL
    public var appleIntelligenceAvailable: Bool

    public init(
        ffmpeg: URL? = nil, ffprobe: URL? = nil, qpdf: URL? = nil,
        temporaryRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EdithStudio", isDirectory: true),
        appleIntelligenceAvailable: Bool = false
    ) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.qpdf = qpdf
        self.temporaryRoot = temporaryRoot
        self.appleIntelligenceAvailable = appleIntelligenceAvailable
    }

    public static let searchDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin",
    ]

    public static func detect(
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        resolve: ((String) -> URL?)? = nil
    ) -> StudioEnvironment {
        let directories =
            (path?.split(separator: ":").map(String.init) ?? []) + searchDirectories
        func locate(_ name: String) -> URL? {
            if let resolve, let url = resolve(name) { return url }
            for directory in directories {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
            return nil
        }
        return StudioEnvironment(
            ffmpeg: locate("ffmpeg"), ffprobe: locate("ffprobe"), qpdf: locate("qpdf"),
            appleIntelligenceAvailable: StudioIntelligence.isModelAvailable)
    }

    public func executable(for engine: StudioEngine) -> URL? {
        switch engine {
        case .ffmpeg: ffmpeg
        case .qpdf: qpdf
        }
    }

    public func satisfies(_ requirement: StudioRequirement) -> Bool {
        switch requirement {
        case let .engine(engine): executable(for: engine) != nil
        case .appleIntelligence: appleIntelligenceAvailable
        case .translation: StudioIntelligence.isTranslationSupported
        }
    }

    public func missing(for tool: StudioTool) -> [StudioRequirement] {
        tool.requirements.filter { !satisfies($0) }
    }

    public func require(_ engine: StudioEngine) throws -> URL {
        guard let url = executable(for: engine) else { throw StudioError.needsEngine(engine) }
        return url
    }
}

public enum StudioIntelligence {
    public static var isModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    public static var isTranslationSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}
