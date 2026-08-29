import AppKit
import EdithCore
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct GitHubRepositoryRenderTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func repositoryRendersAtWideAndNarrowWindowSizes() throws {
        let resource = GitHubRepositoryResource.repository(repository())
        let route = GitHubRoute(host: .github, resource: .repository(repository().repository))

        let wide = try render(
            GitHubRepositoryResourceView(resource: resource, route: route, navigate: { _, _ in }),
            width: 1_240, height: 760)
        let narrow = try render(
            GitHubRepositoryResourceView(resource: resource, route: route, navigate: { _, _ in }),
            width: 680, height: 760)

        #expect(wide.bitmap.size.width == 1_240)
        #expect(narrow.bitmap.size.width == 680)
        #expect(wide.png.count > 12_000)
        #expect(narrow.png.count > 8_000)
        try writeEvidence(wide.png, name: "repository-wide.png")
        try writeEvidence(narrow.png, name: "repository-narrow.png")
    }

    @Test func directoryAndSelectedFileRenderWithoutBlankSurfaces() throws {
        let repository = GitHubRepositoryPath(owner: "acme", name: "orbit")!
        let directory = GitHubDirectorySnapshot(
            repository: repository, revision: "main", path: "Sources/Orbit",
            entries: entries())
        let directoryRoute = GitHubRoute(
            host: .github,
            resource: .content(
                repository: repository, kind: .tree,
                revisionPath: ["main", "Sources", "Orbit"], view: .automatic, lines: nil))
        let file = GitHubFileSnapshot(
            repository: repository, revision: "main", path: "Sources/Orbit/Engine.swift",
            sha: "f00baa", size: 138, text: source, downloadURL: nil, presentation: .text)
        let fileRoute = GitHubRoute(
            host: .github,
            resource: .content(
                repository: repository, kind: .blob,
                revisionPath: ["main", "Sources", "Orbit", "Engine.swift"], view: .automatic,
                lines: .range(3...6)))

        let directoryImage = try render(
            GitHubRepositoryResourceView(
                resource: .directory(directory), route: directoryRoute, navigate: { _, _ in }),
            width: 900, height: 640)
        let fileImage = try render(
            GitHubRepositoryResourceView(
                resource: .file(file), route: fileRoute, navigate: { _, _ in }),
            width: 900, height: 640)

        #expect(directoryImage.png.count > 12_000)
        #expect(fileImage.png.count > 16_000)
        #expect(nonBackgroundRows(in: fileImage.bitmap) > 20)
        try writeEvidence(fileImage.png, name: "file-selected-lines.png")
    }

    private func render(
        _ view: some View, width: CGFloat, height: CGFloat
    ) throws -> (bitmap: NSBitmapImageRep, png: Data) {
        let host = NSHostingView(
            rootView:
                view
                .frame(width: width, height: height)
                .background(DashSkin.paper(true))
                .environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        return (bitmap, png)
    }

    private func nonBackgroundRows(in bitmap: NSBitmapImageRep) -> Int {
        let xValues = stride(from: 20, to: bitmap.pixelsWide - 20, by: 24)
        return (10..<(bitmap.pixelsHigh - 10)).filter { y in
            let colors = xValues.compactMap { bitmap.colorAt(x: $0, y: y) }
            guard let first = colors.first else { return false }
            return colors.contains { color in
                abs(color.redComponent - first.redComponent) > 0.035
                    || abs(color.greenComponent - first.greenComponent) > 0.035
                    || abs(color.blueComponent - first.blueComponent) > 0.035
            }
        }.count
    }

    private func writeEvidence(_ data: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["EDITH_GITHUB_EVIDENCE_DIR"] else {
            return
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name))
    }

    private func repository() -> GitHubRepositoryOverview {
        let repository = GitHubRepositoryPath(owner: "acme", name: "orbit")!
        return GitHubRepositoryOverview(
            repository: repository,
            description: "A native Swift package for reliable orbital calculations.",
            isPrivate: false, isFork: false, isArchived: false, defaultBranch: "main", stars: 128,
            forks: 14, openIssues: 6, language: "Swift", license: "MIT",
            topics: ["swift", "macos", "science"],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            url: URL(string: "https://github.com/acme/orbit")!,
            branches: [
                GitHubBranchSummary(name: "main", sha: "abc123"),
                GitHubBranchSummary(name: "release", sha: "def456"),
            ],
            latestCommit: GitHubCommitSummary(
                sha: "abc123456789", message: "Improve orbit propagation", authorName: "Mina",
                authorLogin: "mina", authoredAt: Date(timeIntervalSince1970: 1_700_000_000),
                url: URL(string: "https://github.com/acme/orbit/commit/abc123456789")),
            entries: entries())
    }

    private func entries() -> [GitHubRepositoryEntry] {
        [
            entry("Sources", kind: .directory), entry("Tests", kind: .directory),
            entry(".gitignore"), entry("AGENTS.md"), entry("LICENSE"), entry("Makefile"),
            entry("Package.resolved"), entry("Package.swift"), entry("README.md"),
        ]
    }

    private func entry(
        _ name: String, kind: GitHubRepositoryEntryKind = .file
    ) -> GitHubRepositoryEntry {
        GitHubRepositoryEntry(
            name: name, path: name, kind: kind, size: kind == .directory ? 0 : 1_024,
            sha: "sha-\(name)", url: URL(string: "https://github.com/acme/orbit/blob/main/\(name)"))
    }

    private var source: String {
        """
        import Foundation

        struct OrbitEngine {
            let period: TimeInterval

            func position(at date: Date) -> SIMD3<Double> {
                let phase = date.timeIntervalSinceReferenceDate / period
                return SIMD3(cos(phase), sin(phase), 0)
            }
        }
        """
    }
}
