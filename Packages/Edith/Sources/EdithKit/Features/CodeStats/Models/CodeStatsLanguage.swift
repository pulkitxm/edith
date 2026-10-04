import Foundation

public enum CodeStatsLanguage {
    public static let other = "Other"

    public static let excludedPathspecs = [
        "**/node_modules/**", "**/dist/**", "**/build/**", "**/vendor/**", "**/.next/**",
        "**/out/**", "**/coverage/**", "**/.turbo/**", "**/*.min.js", "**/*.min.css",
        "**/package-lock.json", "**/yarn.lock", "**/pnpm-lock.yaml", "**/bun.lockb",
        "**/*.lock", "**/go.sum", "**/poetry.lock", "**/composer.lock", "**/Gemfile.lock",
    ].map { ":(exclude,glob)" + $0 }

    private static let lockBasenames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "cargo.lock",
        "poetry.lock", "composer.lock", "gemfile.lock", "go.sum",
    ]

    private static let generatedSegments: Set<String> = [
        "node_modules", "dist", "build", "vendor", ".next", "out", "coverage", ".turbo",
    ]

    private static let specialBasenames = [
        "dockerfile": "Dockerfile", "makefile": "Makefile", "cmakelists.txt": "CMake",
    ]

    private static let extensions: [String: String] = [
        "ts": "TypeScript", "tsx": "TSX", "js": "JavaScript", "jsx": "JSX",
        "mjs": "JavaScript", "cjs": "JavaScript", "py": "Python", "rb": "Ruby", "go": "Go",
        "rs": "Rust", "java": "Java", "kt": "Kotlin", "swift": "Swift", "c": "C",
        "h": "C/C++ Header", "hpp": "C/C++ Header", "cpp": "C++", "cc": "C++", "cxx": "C++",
        "cs": "C#", "php": "PHP", "scala": "Scala", "dart": "Dart", "lua": "Lua", "r": "R",
        "jl": "Julia", "zig": "Zig", "sh": "Shell", "bash": "Shell", "zsh": "Shell",
        "ps1": "PowerShell", "html": "HTML", "css": "CSS", "scss": "SCSS", "sass": "SCSS",
        "less": "Less", "vue": "Vue", "svelte": "Svelte", "json": "JSON", "yaml": "YAML",
        "yml": "YAML", "toml": "TOML", "xml": "XML", "csv": "CSV", "md": "Markdown",
        "mdx": "MDX", "txt": "Text", "sql": "SQL", "proto": "Protobuf", "graphql": "GraphQL",
        "gql": "GraphQL", "ipynb": "Jupyter Notebook",
    ]

    public static func isGenerated(_ path: String) -> Bool {
        let segments = path.lowercased().split(separator: "/", omittingEmptySubsequences: false)
        let base = String(segments.last ?? "")
        if lockBasenames.contains(base) { return true }
        if base.hasSuffix(".min.js") || base.hasSuffix(".min.css") { return true }
        return segments.contains { generatedSegments.contains(String($0)) }
    }

    public static func classify(_ path: String) -> String? {
        if isGenerated(path) { return nil }
        let base = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        if let special = specialBasenames[base] { return special }
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return other }
        return extensions[String(base[base.index(after: dot)...])] ?? other
    }
}
