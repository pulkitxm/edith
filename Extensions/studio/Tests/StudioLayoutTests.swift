import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing
import Vision
@testable import StudioExtension

@MainActor
@Suite(.serialized)
struct StudioLayoutTests {
    @Test func inactivePagesFitCompactRegularAndZoomedWindowsInBothSchemes() throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for (size, scale, scheme) in [
            (NSSize(width: 540, height: 430), 1.0, ColorScheme.dark),
            (NSSize(width: 1_000, height: 700), 1.0, ColorScheme.light),
            (NSSize(width: 760, height: 520), 1.35, ColorScheme.dark),
        ] {
            UIScale.apply(scale)
            for tab in [StudioTab.files, .tools] {
                let model = StudioModel(defaults: StudioTestFiles.defaults(), loadsState: false)
                model.tab = tab
                let host = NSHostingView(
                    rootView: StudioPage(model: model)
                        .environment(\.compactLayout, size.width / scale < 700)
                        .environment(\.colorScheme, scheme)
                        .environment(\.automaticViewActionsEnabled, false)
                        .environment(\.windowVisible, false))
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let minimum = host.fittingSize
                #expect(minimum.width <= size.width)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                let image = try #require(bitmap.cgImage)
                let text = VNRecognizeTextRequest()
                text.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: image).perform([text])
                let labels = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                #expect(
                    labels.contains("Studio") && labels.contains("Files")
                        && labels.contains("Tools"))
                #expect(model.jobs.isEmpty && model.files.isEmpty && model.installing == nil)
                #expect(TestWindowHost.exposedWindows.isEmpty)
                model.shutdown()
            }
        }
    }

    @Test func homeAndNotchCustomizationExposeAllStudioContentKinds() {
        let widget = SurfaceWidget.ability("studio")
        #expect(widget.supportsSourceFilters)
        #expect(widget.sourceTitle == "Media kinds")
        #expect(Set(widget.contentChoices.map(\.id)) == ["files", "projects", "jobs"])
        #expect(
            Set(widget.extensionFields.map(\.0)).isSuperset(of: ["files", "projects", "running"]))
    }
}
