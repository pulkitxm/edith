import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFAuditFailureTests {
    static let settings: [String: [String: StudioValue]] = [
        "pdf.remove-pages": ["pages": .text("1")],
        "pdf.protect": ["userPassword": .text("x")],
        "pdf.redact": ["terms": .text("Body")],
    ]

    static var pdfTools: [String] {
        StudioCatalog.tools.filter {
            $0.id.hasPrefix("pdf.") && $0.isRunnable && $0.accepts(kind: .pdf)
        }
        .map(\.id)
    }

    func inputs(for id: String, bad: URL, good: URL) -> [URL] {
        guard let tool = StudioCatalog.tool(id) else { return [bad] }
        return tool.arity.minimum >= 2 ? [bad, good] : [bad]
    }

    func expectCleanFailure(
        _ space: Workspace, _ id: String, _ inputs: [URL], _ values: [String: StudioValue] = [:]
    ) async {
        await #expect(throws: StudioError.self, "\(id)") {
            try await space.audited(id, inputs, values, environment: space.withoutEngines)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: space.output.path)) ?? []
        #expect(files.isEmpty, "\(id) left \(files)")
    }

    @Test(arguments: pdfTools)
    func brokenAndLockedInputsFailCleanly(_ id: String) async throws {
        let space = try Workspace()
        let good = space.url("good.pdf")
        try AuditPDF.write([.titled("Body text for every tool")], to: good)
        let values = Self.settings[id] ?? [:]
        let empty = space.url("empty.pdf")
        try Data().write(to: empty)
        await expectCleanFailure(space, id, inputs(for: id, bad: empty, good: good), values)
        let garbage = space.url("garbage.pdf")
        try Data("%PDF-1.7\nthis is not a real document\n%%EOF".utf8).write(to: garbage)
        await expectCleanFailure(space, id, inputs(for: id, bad: garbage, good: good), values)
        let text = space.url("notes.txt")
        try Data("plain text".utf8).write(to: text)
        await expectCleanFailure(space, id, inputs(for: id, bad: text, good: good), values)
        guard StudioCatalog.tool(id)?.options.contains(where: { $0.key == "password" }) == true,
            id != "pdf.protect"
        else { return }
        let locked = space.url("locked.pdf")
        try AuditPDF.encrypt(good, to: locked, user: "right", owner: "owner")
        let lockedInputs = inputs(for: id, bad: locked, good: good)
        if id != "pdf.decompress", id != "pdf.linearize" {
            await #expect(throws: StudioError.needsPassword("locked.pdf")) {
                try await space.audited(id, lockedInputs, values, environment: space.withoutEngines)
            }
            var wrong = values
            wrong["password"] = .text("wrong")
            await #expect(throws: StudioError.wrongPassword("locked.pdf")) {
                try await space.audited(id, lockedInputs, wrong, environment: space.withoutEngines)
            }
        }
    }

    @Test func imageToolsRejectBrokenImages() async throws {
        let space = try Workspace()
        let empty = space.url("empty.png")
        try Data().write(to: empty)
        let broken = space.url("broken.jpg")
        try Data("not a jpeg at all".utf8).write(to: broken)
        let pdf = space.url("doc.pdf")
        try AuditPDF.write([.titled("Doc")], to: pdf)
        for id in ["pdf.from-images", "pdf.scan", "pdf.ocr"] {
            await expectCleanFailure(space, id, [empty])
            await expectCleanFailure(space, id, [broken])
        }
        await expectCleanFailure(space, "pdf.from-images", [pdf])
        await expectCleanFailure(space, "pdf.merge", [pdf, empty])
    }

    @Test func missingOrInvalidSettingsAreReportedBeforeAnyWork() async throws {
        let space = try Workspace()
        let pdf = space.url("doc.pdf")
        try AuditPDF.write([.titled("Doc"), .titled("Two")], to: pdf)
        await expectCleanFailure(space, "pdf.remove-pages", [pdf])
        await expectCleanFailure(space, "pdf.protect", [pdf])
        await expectCleanFailure(space, "pdf.watermark", [pdf], ["text": .text("  ")])
        await expectCleanFailure(space, "pdf.watermark", [pdf], ["kind": .text("image")])
        await expectCleanFailure(
            space, "pdf.redact", [pdf], ["emails": .bool(false), "phones": .bool(false)])
        await expectCleanFailure(space, "pdf.reorder", [pdf], ["order": .text("custom")])
        await expectCleanFailure(space, "pdf.split", [pdf], ["mode": .text("chapters")])
        await expectCleanFailure(space, "pdf.to-images", [pdf], ["dpi": .text("5000")])
        await expectCleanFailure(space, "pdf.n-up", [pdf], ["layout": .text("5")])
        await expectCleanFailure(space, "pdf.remove-pages", [pdf], ["pages": .text("1-2")])
        await expectCleanFailure(space, "pdf.split", [pdf], ["ranges": .text("3")])
    }
}
