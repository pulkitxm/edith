import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

@Suite struct TerminalFileLinksTests {
    @Test func aLocalAgentResolvesExistingFilesAgainstItsFolder() {
        let file = "/Users/me/repo/Sources/App.swift"
        let links = Self.local(directory: "/Users/me/repo", files: [file])

        #expect(links.path(for: "Sources/App.swift:42:7") == file)
        #expect(links.path(for: "./Sources/App.swift") == file)
        #expect(links.path(for: "'Sources/App.swift',") == file)
        #expect(links.path(for: "(`Sources/App.swift:12`).") == file)
        #expect(links.path(for: file) == file)
        #expect(links.path(for: "file://\(file)") == file)
        #expect(links.path(for: "Sources/Missing.swift") == nil)
    }

    @Test func aLocalAgentExpandsHomeOnThisMac() {
        let notes = NSString(string: "~/notes.md").expandingTildeInPath
        let links = Self.local(directory: "/tmp", files: [notes])

        #expect(links.path(for: "~/notes.md") == notes)
    }

    @Test func relativePathsTryTheReportedFolderThenTheAgentFolderThenTheGitRoot() {
        let links = Self.local(
            directory: "/Users/me/repo/apps/web",
            files: [
                "/Users/me/repo/.git", "/Users/me/repo/apps/web/src/a.ts",
                "/Users/me/repo/packages/ui/button.tsx", "/tmp/elsewhere/src/a.ts",
            ])

        #expect(links.path(for: "src/a.ts") == "/Users/me/repo/apps/web/src/a.ts")
        #expect(
            links.path(for: "src/a.ts", reportedDirectory: "/tmp/elsewhere")
                == "/tmp/elsewhere/src/a.ts")
        #expect(
            links.path(for: "packages/ui/button.tsx") == "/Users/me/repo/packages/ui/button.tsx")
    }

    @Test func pathsShortenedWithAnEllipsisStillResolve() {
        let links = Self.local(
            directory: "/Users/me/repo",
            files: ["/Users/me/repo/scratch/pretooluse-hook.sh", "/Users/me/repo/src/app.ts"])

        #expect(
            links.path(for: "/Users/me/repo/scratch/preto…")
                == "/Users/me/repo/scratch/pretooluse-hook.sh")
        #expect(links.path(for: "…/src/app.ts") == "/Users/me/repo/src/app.ts")
        #expect(links.path(for: "/Users/me/repo/scratch/zzz…") == nil)
    }

    @Test func aRemoteAgentAcceptsPathShapedTextWithoutTouchingThisMac() {
        let links = TerminalFileLinks(directory: "/home/me/repo", fileSystem: nil, reveal: { _ in })

        #expect(links.path(for: "Sources/App.swift:42") == "/home/me/repo/Sources/App.swift")
        #expect(links.path(for: "README.md") == "/home/me/repo/README.md")
        #expect(links.path(for: "../other/main.c") == "/home/me/other/main.c")
        #expect(links.path(for: "/etc/hosts") == "/etc/hosts")
        #expect(links.path(for: "~/notes.txt") == "~/notes.txt")
        #expect(links.path(for: "…/src/app.ts") == "/home/me/repo/src/app.ts")
        #expect(links.path(for: "/var/log/sys…") == "/var/log/sys…")
    }

    @Test(arguments: [
        "hello", "https://example.com/a.txt", "localhost:3000", "...", "/", "~", "two words.txt",
        "v1.", "…", "a…b/c.txt",
    ])
    func aRemoteAgentIgnoresTextThatIsNotAPath(_ text: String) {
        let links = TerminalFileLinks(directory: "/home/me/repo", fileSystem: nil, reveal: { _ in })

        #expect(links.path(for: text) == nil)
    }

    @Test func relativePathsNeedAnAbsoluteAgentFolder() {
        let links = TerminalFileLinks(directory: "", fileSystem: nil, reveal: { _ in })

        #expect(links.path(for: "Sources/App.swift") == nil)
        #expect(links.path(for: "/srv/App.swift") == "/srv/App.swift")
    }

    @Test @MainActor func commandClickedPathsRevealWhileWebLinksStillOpen() async throws {
        let view = GhosttyTerminalView(
            launch: GhosttyLaunch(executable: "/bin/cat", arguments: [], environment: []))
        var revealed: [String] = []
        var opened: [URL] = []
        view.openResolvedURL = { opened.append($0) }
        view.fileLinks = TerminalFileLinks(
            directory: "/srv/repo", fileSystem: nil, reveal: { revealed.append($0) })

        #expect(view.resolvedTarget(for: "src/main.rs:10")?.openTitle == "Show in Files")
        #expect(view.openTerminalTarget("src/main.rs:10"))
        #expect(view.openTerminalTarget("https://example.com"))
        #expect(!view.openTerminalTarget("plain"))
        try await Task.sleep(for: .milliseconds(100))

        #expect(revealed == ["/srv/repo/src/main.rs"])
        #expect(opened.map(\.absoluteString) == ["https://example.com"])
    }

    @Test @MainActor func terminalsWithoutFileLinksKeepOpeningLocalFiles() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-link-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let view = GhosttyTerminalView(
            launch: GhosttyLaunch(executable: "/bin/cat", arguments: [], environment: []))
        var opened: [URL] = []
        view.openResolvedURL = { opened.append($0) }

        #expect(view.resolvedTarget(for: file.path)?.openTitle == "Open Link")
        #expect(view.openTerminalTarget(file.path))
        try await Task.sleep(for: .milliseconds(100))

        #expect(opened.map(\.path) == [file.standardizedFileURL.path])
    }

    @Test @MainActor func commandClickingPrintedPathsInALiveTerminalRevealsThem() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-path-click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("src/app.ts").standardizedFileURL.path
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        let lines = [
            "Edited  src/app.ts:3", "Path  \(file)", "Failed: \(root.path)/src/ap…",
            "Long: …/src/app.ts",
        ]
        let command =
            "printf '\\n\\n\(lines.map { "  \($0)" }.joined(separator: "\\n"))\\n'; sleep 30"
        let view = GhosttyTerminalView(
            launch: GhosttyLaunch(
                executable: "/bin/sh", arguments: ["-c", command],
                environment: ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }),
            theme: GhosttyTheme(
                background: "#111111", foreground: "#eeeeee", cursor: "#eeeeee", fontSize: 13))
        view.frame = NSRect(x: 0, y: 0, width: 1400, height: 600)
        let window = TestWindowHost.window(contentRect: view.frame)
        window.contentView = view
        defer {
            window.contentView = nil
            view.shutdown()
        }
        var revealed: [String] = []
        view.fileLinks = TerminalFileLinks(
            directory: root.path, fileSystem: .local, reveal: { revealed.append($0) })
        let commandFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICELCMDKEYMASK))
        let commandDown = try #require(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: commandFlags,
                timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        let words = ["src/app.ts:3", file, "\(root.path)/src/ap…", "…/src/app.ts"]
        var points: [String: NSPoint] = [:]
        for _ in 0..<50 where points.count < words.count {
            for y in stride(from: 594, through: 440, by: -4) {
                for x in stride(from: 4, through: 200, by: 8) where points.count < words.count {
                    let point = NSPoint(x: x, y: y)
                    view.mouseMoved(
                        with: try #require(
                            NSEvent.mouseEvent(
                                with: .mouseMoved, location: point, modifierFlags: commandFlags,
                                timestamp: 1, windowNumber: window.windowNumber, context: nil,
                                eventNumber: 1, clickCount: 0, pressure: 0)))
                    view.applyModifierChange(
                        commandDown, mouseOverSurface: true, pressedMouseButtons: 0)
                    if let word = view.terminalTargetAtPointer(), words.contains(word),
                        points[word] == nil
                    {
                        points[word] = point
                    }
                }
            }
            if points.count < words.count { try await Task.sleep(for: .milliseconds(20)) }
        }

        for word in words {
            let point = try #require(points[word])
            revealed = []
            view.mouseDown(
                with: try #require(
                    NSEvent.mouseEvent(
                        with: .leftMouseDown, location: point, modifierFlags: commandFlags,
                        timestamp: 3, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 2, clickCount: 1, pressure: 0)))
            view.mouseUp(
                with: try #require(
                    NSEvent.mouseEvent(
                        with: .leftMouseUp, location: point, modifierFlags: commandFlags,
                        timestamp: 4, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 3, clickCount: 1, pressure: 0)))
            try await Task.sleep(for: .milliseconds(150))
            #expect(revealed == [file], "\(word)")
        }
    }

    private static func local(directory: String, files: Set<String>) -> TerminalFileLinks {
        TerminalFileLinks(
            directory: directory,
            fileSystem: TerminalFileSystem(
                fileExists: { files.contains($0) },
                contents: { folder in
                    files.compactMap { path in
                        let url = URL(fileURLWithPath: path)
                        return url.deletingLastPathComponent().path == folder
                            ? url.lastPathComponent : nil
                    }
                }),
            reveal: { _ in })
    }
}
