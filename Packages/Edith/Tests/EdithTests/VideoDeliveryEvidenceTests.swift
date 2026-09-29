import AppKit
import CoreImage
import SwiftUI
import Testing
@testable import Edith

@MainActor
@Suite(.serialized) struct VideoDeliveryEvidenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDITH_DELIVERY_EVIDENCE_DIR"] != nil))
    func nativeExportSheetShowsVerifiedSyntheticDelivery() async throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try #require(environment["EDITH_TEST_RUNTIME_ROOT"])
        let dataRoot = try #require(environment["EDITH_DATA_ROOT"])
        try #require(dataRoot.hasPrefix(runtime + "/"))
        let output = URL(
            fileURLWithPath: try #require(environment["EDITH_DELIVERY_EVIDENCE_DIR"]),
            isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let imageURL = URL(fileURLWithPath: runtime).appendingPathComponent("synthetic.png")
        let image = CIImage(color: CIColor(red: 0.15, green: 0.45, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        try CIContext().writePNGRepresentation(
            of: image, to: imageURL, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let source = try await VideoStillMedia.create(from: imageURL, duration: 1)
        var project = VideoProject.create()
        project.addAsset(source, duration: 1, width: 1280, height: 720)
        let projectURL = URL(fileURLWithPath: runtime)
            .appendingPathComponent("synthetic.openscreen")
        try project.save(to: projectURL)
        let model = VideoEditorModel()
        defer { model.close() }
        model.openProject(at: projectURL)
        let deadline = Date().addingTimeInterval(30)
        while model.pipeline == nil, model.errorMessage == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pipeline = try #require(model.pipeline)
        let exporter = VideoExporter()
        try render(
            VideoExportSheet(model: model, exporter: exporter),
            to: output.appendingPathComponent("export-settings.png"))
        let destination = output.appendingPathComponent("synthetic-delivery.mp4")
        exporter.start(to: destination) { progress in
            let report = try await pipeline.export(
                to: destination, overwrite: true, progress: progress)
            exporter.setReport(report, for: destination)
        }
        let exportDeadline = Date().addingTimeInterval(60)
        while exporter.isExporting, Date() < exportDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(exporter.job?.phase == .finished)
        let report = try #require(exporter.job?.report)
        #expect(report.width == 1280)
        #expect(report.height == 720)
        #expect(report.frameCount == 60)
        try render(
            VideoExportSheet(model: model, exporter: exporter),
            to: output.appendingPathComponent("export-finished.png"))
    }

    private func render(_ view: some View, to output: URL) throws {
        let host = NSHostingView(
            rootView: view.background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil })
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.center()
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        redraw(host)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.path]
        try capture.run()
        capture.waitUntilExit()
        try #require(capture.terminationStatus == 0)
        let data = try Data(contentsOf: output)
        #expect(data.count > 5_000)
    }

    private func redraw(_ view: NSView) {
        for child in view.subviews { redraw(child) }
        view.needsDisplay = true
        view.displayIfNeeded()
    }
}
