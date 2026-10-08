import Foundation

public enum LaTeXLocation: String, Codable, CaseIterable, Sendable {
    case disk
    case github

    public var title: String { self == .disk ? "On disk" : "GitHub repository" }
}

public enum LaTeXCompiler: String, Codable, CaseIterable, Sendable {
    case tectonic
    case pdfLatex
    public var title: String { self == .tectonic ? "Tectonic" : "pdfLaTeX" }
}

public struct LaTeXProject: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var location: LaTeXLocation
    public var compiler: LaTeXCompiler
    public var sourcePath: String
    public var repository: String
    public var baseBranch: String
    public var reviewBranch: String?
    public var pullRequest: Int?

    public init(
        id: UUID = UUID(), name: String, location: LaTeXLocation, sourcePath: String,
        compiler: LaTeXCompiler = .tectonic,
        repository: String = "", baseBranch: String = "", reviewBranch: String? = nil,
        pullRequest: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.location = location
        self.compiler = compiler
        self.sourcePath = sourcePath
        self.repository = repository
        self.baseBranch = baseBranch
        self.reviewBranch = reviewBranch
        self.pullRequest = pullRequest
    }

    public var workflowPath: String {
        ".github/workflows/edith-latex-\(id.uuidString.lowercased()).yml"
    }

    public var pdfURL: URL {
        URL(fileURLWithPath: sourcePath).deletingPathExtension().appendingPathExtension("pdf")
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LaTeXError.message("Give the project a name.")
        }
        guard sourcePath.lowercased().hasSuffix(".tex") else {
            throw LaTeXError.message("Choose a .tex source file.")
        }
        if location == .disk {
            guard sourcePath.hasPrefix("/") else {
                throw LaTeXError.message("Choose an absolute path to a local .tex file.")
            }
        } else {
            guard Self.validRepository(repository), Self.validRepositoryPath(sourcePath) else {
                throw LaTeXError.message("Use owner/repository and a relative .tex path inside it.")
            }
            guard !baseBranch.isEmpty, !baseBranch.contains(where: { $0.isNewline }) else {
                throw LaTeXError.message("Choose the repository's base branch.")
            }
        }
    }

    public static func validRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2
            && parts.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
                    && $0.allSatisfy {
                        $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0))
                    }
            }
    }

    public static func validRepositoryPath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.hasPrefix(".github/")
            && !value.contains("\\") && !value.contains("${{")
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}

public enum LaTeXError: LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}

public struct LaTeXSource: Sendable {
    public let text: String
    public let revision: String
    public let baseCommit: String

    public init(text: String, revision: String, baseCommit: String = "") {
        self.text = text
        self.revision = revision
        self.baseCommit = baseCommit
    }
}

public struct LaTeXProjectStore: Sendable {
    public let url: URL

    public init(url: URL = DataRoot.support.appendingPathComponent("latex/projects.json")) {
        self.url = url
    }

    public func load() throws -> [LaTeXProject] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([LaTeXProject].self, from: Data(contentsOf: url))
    }

    public func save(_ projects: [LaTeXProject]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(projects).write(to: url, options: .atomic)
    }
}
