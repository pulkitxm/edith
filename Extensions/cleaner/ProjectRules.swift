import Foundation

public struct ProjectRule: Sendable {
    public let categoryID: String
    public let directories: Set<String>
    public let prefixes: [String]
    public let suffixes: [String]
    public let markers: [String]
    public let requiredContents: [String]
    public let requiresIgnore: Bool

    public init(
        _ categoryID: String, directories: Set<String> = [], prefixes: [String] = [],
        suffixes: [String] = [], markers: [String] = [], requiredContents: [String] = [],
        requiresIgnore: Bool = false
    ) {
        self.categoryID = categoryID
        self.directories = directories
        self.prefixes = prefixes
        self.suffixes = suffixes
        self.markers = markers
        self.requiredContents = requiredContents
        self.requiresIgnore = requiresIgnore
    }

    func namesMatch(_ name: String) -> Bool {
        directories.contains(name) || prefixes.contains { name.hasPrefix($0) }
            || suffixes.contains { name.hasSuffix($0) }
    }

    func markersMatch(_ siblings: [String]) -> Bool {
        guard !markers.isEmpty else { return true }
        return markers.contains { marker in
            if marker.hasPrefix("*") {
                let suffix = String(marker.dropFirst())
                return siblings.contains { $0.hasSuffix(suffix) }
            }
            return siblings.contains(marker)
        }
    }
}

public struct ProjectCategory: Sendable {
    public let id: String
    public let name: String
    public let detail: String
}

public enum ProjectRules {
    public static let categories: [ProjectCategory] = [
        .init(
            id: "nodeModules", name: "node_modules",
            detail: "JavaScript dependencies, restored by install."),
        .init(
            id: "jsCaches", name: "JavaScript framework caches",
            detail: "Next, Nuxt, Svelte, Astro, Angular, Vite, Turbo, Nx, Expo and similar."),
        .init(
            id: "jsBuild", name: "JavaScript build output",
            detail: "Git-ignored dist, build and out folders, rebuilt on next build."),
        .init(
            id: "rustTarget", name: "Cargo target",
            detail: "Rust build output, rebuilt on next build."),
        .init(
            id: "jvm", name: "JVM build output",
            detail: "Gradle, Maven, sbt, Kotlin and Clojure build folders."),
        .init(
            id: "swiftBuild", name: "Swift and Xcode build output",
            detail: "SwiftPM .build folders and project DerivedData."),
        .init(
            id: "pods", name: "CocoaPods and Carthage",
            detail: "Restored by pod install or carthage bootstrap."),
        .init(
            id: "pycache", name: "Python caches",
            detail: "Bytecode, pytest, mypy, ruff, tox and notebook checkpoints."),
        .init(
            id: "pyvenv", name: "Python virtualenvs",
            detail: "Recreated from requirements or the lockfile."),
        .init(
            id: "pyBuild", name: "Python build output",
            detail: "Git-ignored build, dist and egg-info folders."),
        .init(
            id: "dart", name: "Dart and Flutter build output",
            detail: "Rebuilt by flutter pub get and the next build."),
        .init(
            id: "native", name: "C and C++ build output",
            detail: "CMake and Meson build folders."),
        .init(
            id: "dotnet", name: ".NET build output",
            detail: "bin, obj and TestResults, rebuilt by dotnet build."),
        .init(
            id: "beam", name: "Elixir and Erlang build output",
            detail: "_build, deps and language server caches."),
        .init(
            id: "haskell", name: "Haskell build output",
            detail: "Stack and Cabal build folders."),
        .init(
            id: "zig", name: "Zig build output", detail: "Zig caches and zig-out."),
        .init(
            id: "vendor", name: "Vendored dependencies",
            detail: "Git-ignored Go and Composer vendor folders, restored by install."),
        .init(
            id: "gameEngines", name: "Game engine caches",
            detail: "Unity Library and Temp, Unreal Intermediate, Godot imports."),
        .init(
            id: "infra", name: "Infrastructure tool caches",
            detail: "Terraform providers, Serverless, SAM and CDK output."),
        .init(
            id: "testReports", name: "Test reports and coverage",
            detail: "Playwright reports, coverage and nyc output."),
        .init(
            id: "otherBuild", name: "Other build output",
            detail: "OCaml, Gleam, Elm, Nim, Jekyll and R project caches."),
    ]

    private static let packageJSON = ["package.json"]
    private static let gradle = [
        "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
    ]
    private static let pythonProject = [
        "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile", "poetry.lock",
    ]
    private static let dotnetProject = ["*.csproj", "*.fsproj", "*.vbproj", "*.sln"]

    public static let rules: [ProjectRule] = [
        ProjectRule("nodeModules", directories: ["node_modules"]),
        ProjectRule(
            "jsCaches",
            directories: [
                ".next", ".nuxt", ".svelte-kit", ".astro", ".angular", ".docusaurus", ".expo",
                ".parcel-cache", ".turbo", ".nx", ".swc", ".vite", ".wrangler", ".vinxi",
                ".tanstack", ".react-router", ".vercel", ".netlify", ".open-next", ".metro",
                "storybook-static",
            ], markers: packageJSON),
        ProjectRule(
            "jsCaches", directories: [".output"],
            markers: ["nuxt.config.ts", "nuxt.config.js", "app.config.ts"]),
        ProjectRule(
            "jsCaches", directories: [".cache"],
            markers: ["gatsby-config.js", "gatsby-config.ts", "gatsby-config.mjs"]),
        ProjectRule(
            "jsBuild", directories: ["dist", "build", "out", ".output"], markers: packageJSON,
            requiresIgnore: true),
        ProjectRule("rustTarget", directories: ["target", ".xwin-cache"], markers: ["Cargo.toml"]),
        ProjectRule(
            "jvm", directories: ["target"],
            markers: ["pom.xml", "build.sbt", "project.clj", "deps.edn"]),
        ProjectRule(
            "jvm", directories: ["build", ".gradle", ".kotlin", ".cxx", "externalNativeBuild"],
            markers: gradle),
        ProjectRule("jvm", directories: [".bloop", ".metals", ".bsp"], markers: ["build.sbt"]),
        ProjectRule("jvm", directories: [".cpcache"], markers: ["deps.edn"]),
        ProjectRule("swiftBuild", directories: [".build", ".swiftpm"], markers: ["Package.swift"]),
        ProjectRule(
            "swiftBuild", directories: ["DerivedData"],
            markers: ["*.xcodeproj", "*.xcworkspace", "Package.swift"]),
        ProjectRule("pods", directories: ["Pods"], markers: ["Podfile"]),
        ProjectRule("pods", directories: ["Carthage"], markers: ["Cartfile"]),
        ProjectRule(
            "pycache",
            directories: [
                "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox",
                ".hypothesis", "__pypackages__", ".ipynb_checkpoints", ".pytype", ".pyre",
            ]),
        ProjectRule(
            "pyvenv", directories: [".venv", "venv", "env", ".env", "virtualenv"],
            requiredContents: ["pyvenv.cfg"]),
        ProjectRule("pyvenv", directories: [".pixi"], markers: ["pixi.toml"]),
        ProjectRule(
            "pyBuild", directories: ["build", "dist", ".eggs"], markers: pythonProject,
            requiresIgnore: true),
        ProjectRule("pyBuild", suffixes: [".egg-info"], markers: pythonProject),
        ProjectRule("dart", directories: [".dart_tool", "build"], markers: ["pubspec.yaml"]),
        ProjectRule(
            "native", directories: ["build", "CMakeFiles", "out"], prefixes: ["cmake-build-"],
            markers: ["CMakeLists.txt"]),
        ProjectRule("native", directories: ["build", "builddir"], markers: ["meson.build"]),
        ProjectRule(
            "dotnet", directories: ["bin", "obj", "TestResults"], markers: dotnetProject),
        ProjectRule(
            "beam",
            directories: ["_build", "deps", ".elixir_ls", ".lexical", ".elixir-tools", "cover"],
            markers: ["mix.exs"]),
        ProjectRule("beam", directories: ["_build"], markers: ["rebar.config"]),
        ProjectRule("haskell", directories: [".stack-work"], markers: ["stack.yaml"]),
        ProjectRule(
            "haskell", directories: ["dist-newstyle"], markers: ["cabal.project", "*.cabal"]),
        ProjectRule(
            "zig", directories: ["zig-cache", ".zig-cache", "zig-out"],
            markers: ["build.zig"]),
        ProjectRule(
            "vendor", directories: ["vendor"], markers: ["go.mod", "composer.json"],
            requiresIgnore: true),
        ProjectRule(
            "gameEngines", directories: ["Library", "Temp", "Obj", "Logs", "MemoryCaptures"],
            markers: ["ProjectSettings"]),
        ProjectRule(
            "gameEngines", directories: ["Intermediate", "DerivedDataCache", "Binaries"],
            markers: ["*.uproject"]),
        ProjectRule("gameEngines", directories: [".godot"], markers: ["project.godot"]),
        ProjectRule(
            "infra", directories: [".terraform"], markers: [".terraform.lock.hcl", "*.tf"]),
        ProjectRule(
            "infra", directories: [".serverless"],
            markers: ["serverless.yml", "serverless.yaml", "serverless.ts"]),
        ProjectRule(
            "infra", directories: [".aws-sam"],
            markers: ["template.yaml", "template.yml", "samconfig.toml"]),
        ProjectRule("infra", directories: ["cdk.out"], markers: ["cdk.json"]),
        ProjectRule(
            "testReports", directories: ["playwright-report", "test-results", "blob-report"],
            markers: ["playwright.config.ts", "playwright.config.js", "playwright.config.mjs"]),
        ProjectRule("testReports", directories: ["coverage", ".nyc_output"], markers: packageJSON),
        ProjectRule("otherBuild", directories: ["_build"], markers: ["dune-project"]),
        ProjectRule("otherBuild", directories: ["build"], markers: ["gleam.toml"]),
        ProjectRule("otherBuild", directories: ["elm-stuff"], markers: ["elm.json"]),
        ProjectRule("otherBuild", directories: ["nimcache"]),
        ProjectRule(
            "otherBuild", directories: ["_site", ".jekyll-cache"], markers: ["_config.yml"]),
        ProjectRule("otherBuild", directories: [".Rproj.user"], markers: ["*.Rproj"]),
    ]

    public static var categoryIDs: [String] { categories.map(\.id) }

    public static func category(_ id: String) -> ProjectCategory? {
        categories.first { $0.id == id }
    }

    public static func match(
        name: String, directory: URL, siblings: [String], ignore: GitIgnoreLookup
    ) -> ProjectRule? {
        let fm = FileManager.default
        return rules.first { rule in
            guard rule.namesMatch(name), rule.markersMatch(siblings) else { return false }
            if !rule.requiredContents.isEmpty {
                let child = directory.appendingPathComponent(name)
                guard
                    rule.requiredContents.contains(where: {
                        fm.fileExists(atPath: child.appendingPathComponent($0).path)
                    })
                else { return false }
            }
            return !rule.requiresIgnore || ignore.ignores(name, in: directory)
        }
    }
}

public final class GitIgnoreLookup {
    private var patterns: [String: [String]] = [:]

    public init() {}

    public func ignores(_ name: String, in directory: URL) -> Bool {
        var current = directory
        for _ in 0..<6 {
            if patternsFor(current).contains(where: { Self.matches($0, name: name) }) {
                return true
            }
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return false
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return false }
            current = parent
        }
        return false
    }

    private func patternsFor(_ directory: URL) -> [String] {
        if let cached = patterns[directory.path] { return cached }
        let file = directory.appendingPathComponent(".gitignore")
        let lines =
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") }
        patterns[directory.path] = lines
        return lines
    }

    static func matches(_ pattern: String, name: String) -> Bool {
        var trimmed = pattern
        if trimmed.hasPrefix("**/") { trimmed.removeFirst(3) }
        if trimmed.hasPrefix("/") { trimmed.removeFirst() }
        if trimmed.hasSuffix("/**") { trimmed.removeLast(3) }
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed == name
    }
}
