import AppKit
import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct ClipboardReadinessCopyTests {
    @Test func readinessUsesTheDaemonAndPreservesEmptyDegradedAndFailureStates() async throws {
        let fixture = try ClipboardCopyFixture()
        defer { fixture.cleanup() }
        let runtime = AgentRuntime(build: "clipboard-readiness", store: nil)
        await fixture.service.register(on: runtime)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = AgentClipboardClient(client: listener.client())
        #expect(
            await ExtensionLiveAdapters.clipboardReadiness(client: client)
                == .empty("Clipboard history is ready and empty."))
        let capture = fixture.capture("fixture", ext: "txt")
        _ = try await client.capture(capture)
        #expect(
            await ExtensionLiveAdapters.clipboardReadiness(client: client)
                == .ready("Clipboard history entries: 1."))
        let stored = try await client.blob(id: capture.id)
        let file = fixture.root.appendingPathComponent("blobs/" + stored.entry.sha256 + ".txt")
        try FileManager.default.removeItem(at: file)
        #expect(
            await ExtensionLiveAdapters.clipboardReadiness(client: client)
                == .degraded("Clipboard entries missing payloads: 1."))
        try Data("corrupt".utf8).write(
            to: fixture.root.appendingPathComponent("index.jsonl"), options: .atomic)
        guard case .failed = await ExtensionLiveAdapters.clipboardReadiness(client: client) else {
            Issue.record("Corrupt clipboard storage was not reported by the daemon.")
            return
        }
        await runtime.shutdown()
        guard case .failed = await ExtensionLiveAdapters.clipboardReadiness(client: client) else {
            Issue.record("An unavailable daemon was not reported by clipboard readiness.")
            return
        }
    }

    @MainActor @Test func daemonPreparedRichTextCopiesWithoutLocalConversion() async throws {
        let fixture = try ClipboardCopyFixture()
        defer { fixture.cleanup() }
        let runtime = AgentRuntime(build: "clipboard-copy", store: nil)
        await fixture.service.register(on: runtime)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = AgentClipboardClient(client: listener.client())
        let html = fixture.capture(
            "<html><body><p>Complete &amp; formatted</p></body></html>", ext: "html")
        _ = try await client.capture(html)
        let formatted = try await client.copy(id: html.id)
        #expect(formatted.data == html.data)
        #expect(formatted.text == "Complete & formatted")
        #expect(!formatted.plainTextOnly)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        ClipboardRepository.copyToPasteboard(formatted, pasteboard: pasteboard)
        #expect(pasteboard.data(forType: .html) == html.data)
        #expect(pasteboard.string(forType: .string) == "Complete & formatted")
        let plain = try await client.copy(id: html.id, plainTextOnly: true)
        #expect(plain.data.isEmpty)
        #expect(plain.plainTextOnly)
        ClipboardRepository.copyToPasteboard(plain, pasteboard: pasteboard)
        #expect(pasteboard.data(forType: .html) == nil)
        #expect(pasteboard.string(forType: .string) == "Complete & formatted")
        #expect(pasteboard.data(forType: .init(ClipboardPasteboardFilter.edithOwnTag)) != nil)
        await runtime.shutdown()
    }

    @Test func fullTextAndFileListsArePreparedBeforeTheUIReceivesThem() async throws {
        let fixture = try ClipboardCopyFixture()
        defer { fixture.cleanup() }
        let runtime = AgentRuntime(build: "clipboard-complete", store: nil)
        await fixture.service.register(on: runtime)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = AgentClipboardClient(client: listener.client())
        let value = String(repeating: "complete text\n", count: 1000)
        let text = fixture.capture(value, ext: "txt")
        _ = try await client.capture(text)
        let plain = try await client.copy(id: text.id, plainTextOnly: true)
        #expect(plain.text == value)
        #expect(plain.data.isEmpty)
        let urls = [
            URL(fileURLWithPath: "/tmp/first.txt"), URL(fileURLWithPath: "/tmp/second.txt"),
        ]
        let files = ClipboardCapture(
            payload: .init(
                data: try JSONEncoder().encode(urls.map(\.absoluteString)),
                types: ["public.file-url"], ext: "files", preview: "2 files"), sourceApp: nil,
            sourceBundleID: nil)
        _ = try await client.capture(files)
        let payload = try await client.copy(id: files.id)
        #expect(payload.urls == urls)
        #expect(payload.data.isEmpty)
        await runtime.shutdown()
    }

    @Test func richTextConversionIsBoundedAndHTMLCannotReadExternalEntities() throws {
        let entry = ClipboardEntry(
            sha256: "fixture", types: ["public.rtf"], ext: "rtf",
            sourceApp: nil, sourceBundleID: nil, size: (1 << 20) + 1, preview: "Rich text")
        let payload = ClipboardStoredPayload(
            entry: entry, data: Data(repeating: 0, count: entry.size))
        #expect(throws: AgentError.self) {
            try ClipboardPreviewPreparation.copy(payload, plainTextOnly: true)
        }
        #expect(
            try ClipboardPreviewPreparation.copy(payload, plainTextOnly: false).data.count
                == entry.size)
        let fixture = try ClipboardCopyFixture()
        defer { fixture.cleanup() }
        let secret = fixture.root.appendingPathComponent("external.txt")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data("private external fixture".utf8).write(to: secret)
        let html =
            "<!DOCTYPE html [<!ENTITY external SYSTEM '\(secret.absoluteString)'>]><html><body>Visible &external;</body></html>"
        let htmlEntry = ClipboardEntry(
            sha256: "fixture", types: ["public.html"], ext: "html",
            sourceApp: nil, sourceBundleID: nil, size: html.utf8.count, preview: "HTML")
        let converted = try ClipboardPreviewPreparation.copy(
            .init(entry: htmlEntry, data: Data(html.utf8)), plainTextOnly: true)
        #expect(!(converted.text?.contains("private external fixture") ?? false))
    }
}

private struct ClipboardCopyFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "clipboard-copy-" + UUID().uuidString
    let defaults: UserDefaults
    let service: ClipboardService

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        service = ClipboardService(archive: .init(root: root), defaults: defaults, changed: {})
    }

    func capture(_ text: String, ext: String) -> ClipboardCapture {
        ClipboardCapture(
            payload: .init(
                data: Data(text.utf8), types: ["public." + ext], ext: ext,
                preview: "fixture"), sourceApp: nil, sourceBundleID: nil)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
