import Foundation
import Testing

@testable import CleanerExtension

@Suite struct ProjectRulesTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func make(_ root: URL, _ paths: [String]) throws {
        for path in paths {
            let url = root.appendingPathComponent(path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true)
                try Data(repeating: 1, count: 2048).write(
                    to: url.appendingPathComponent("blob.bin"))
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
        }
    }

    private func scan(_ root: URL) -> [String: [String]] {
        JunkScanner.scanProjectJunk(roots: [root]) { _ in }
            .reduce(into: [:]) { result, category in
                result[category.id] = category.items.map {
                    $0.path.pathComponents.suffix(2).joined(separator: "/")
                }.sorted()
            }
    }

    @Test func buildFoldersNeedTheirProjectMarker() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try make(
            root,
            [
                "rust/Cargo.toml", "rust/target/",
                "maven/pom.xml", "maven/target/",
                "notes/target/",
                "android/build.gradle.kts", "android/build/", "android/.gradle/",
                "plain/build/",
                "swift/Package.swift", "swift/.build/",
                "flutter/pubspec.yaml", "flutter/.dart_tool/",
                "cpp/CMakeLists.txt", "cpp/cmake-build-debug/",
                "dotnet/App.csproj", "dotnet/bin/", "dotnet/obj/",
                "zig/build.zig", "zig/.zig-cache/",
                "elixir/mix.exs", "elixir/_build/",
            ])

        let found = scan(root)
        #expect(found["rustTarget"] == ["rust/target"])
        #expect(found["jvm"] == ["android/.gradle", "android/build", "maven/target"])
        #expect(found["swiftBuild"] == ["swift/.build"])
        #expect(found["dart"] == ["flutter/.dart_tool"])
        #expect(found["native"] == ["cpp/cmake-build-debug"])
        #expect(found["dotnet"] == ["dotnet/bin", "dotnet/obj"])
        #expect(found["zig"] == ["zig/.zig-cache"])
        #expect(found["beam"] == ["elixir/_build"])
        #expect(
            !found.values.joined().contains { $0.hasPrefix("notes/") || $0.hasPrefix("plain/") })
    }

    @Test func outputFoldersOnlyCountWhenGitIgnored() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try make(
            root,
            [
                "web/package.json", "web/dist/", "web/.next/",
                "action/package.json", "action/dist/",
                "go/go.mod", "go/vendor/",
            ])
        try Data("node_modules\n/dist/\n".utf8).write(
            to: root.appendingPathComponent("web/.gitignore"))

        let found = scan(root)
        #expect(found["jsBuild"] == ["web/dist"])
        #expect(found["jsCaches"] == ["web/.next"])
        #expect(found["vendor"] == nil)
    }

    @Test func virtualenvsNeedPyvenvConfig() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try make(root, ["app/.venv/pyvenv.cfg", "app/.venv/lib/", "app/env/settings/"])

        #expect(scan(root)["pyvenv"] == ["app/.venv"])
    }

    @Test func ignorePatternsMatchCommonForms() {
        for pattern in ["dist", "/dist", "dist/", "**/dist", "dist/**"] {
            #expect(GitIgnoreLookup.matches(pattern, name: "dist"))
        }
        #expect(!GitIgnoreLookup.matches("dist-old", name: "dist"))
    }

    @Test func everyRuleBelongsToADeclaredCategory() {
        let declared = Set(ProjectRules.categoryIDs)
        #expect(ProjectRules.rules.allSatisfy { declared.contains($0.categoryID) })
        #expect(declared.count == ProjectRules.categories.count)
    }
}
