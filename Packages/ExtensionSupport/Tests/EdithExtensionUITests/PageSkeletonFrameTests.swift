import AppKit
import EdithExtensionCore
import EdithExtensionTestSupport
import SwiftUI
import Testing

@testable import EdithExtensionUI

private final class SyntheticFormSettings: ControlSettingsPresenting {
    let load = ContentLoad()
    var error: String?
    var ready: Bool { load.hasContent }
    let active = false
    let running = false

    func changed() {}
    func refresh() async {}
}

private struct SyntheticRows: View {
    let count: Int

    var body: some View {
        VStack(spacing: UIScale.pt(12)) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: UIScale.pt(10)) {
                    RoundedRectangle(cornerRadius: UIScale.pt(7)).fill(.secondary)
                        .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text("Synthetic row \(index + 1)").font(.edithText(.body))
                        Text("Synthetic detail").font(.edithText(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("42").font(.edithText(.body)).monospacedDigit()
                }
            }
        }
    }
}

private struct SyntheticRecipeContent: View {
    let layout: PageSkeletonLayout
    @Environment(\.compactLayout) private var compact

    var body: some View {
        switch layout {
        case .analytics:
            PageMetricGrid {
                ForEach(0..<4, id: \.self) { index in
                    PageMetric(title: "Metric \(index + 1)", value: "1,204", detail: "Last 7 days")
                }
            }
            PageCard(title: "Activity") {
                Rectangle().fill(.secondary).frame(height: UIScale.pt(160))
            }
            PageCard { SyntheticRows(count: 6) }
        case .list:
            PageCard { SyntheticRows(count: 6) }
        case .fullList:
            PageCard { SyntheticRows(count: 12) }
        case .cards:
            LazyVGrid(
                columns: PageMetrics.cardColumns(compact, minimum: 260, spacing: 12),
                spacing: UIScale.pt(PageMetrics.cardSpacing)
            ) {
                ForEach(0..<6, id: \.self) { index in
                    PageCard(title: "Card \(index + 1)") { SyntheticRows(count: 1) }
                }
            }
        case .editor:
            PageCard {
                RoundedRectangle(cornerRadius: UIScale.pt(12)).fill(.secondary)
                    .frame(height: UIScale.pt(280))
            }
        case .form:
            SyntheticForm()
        }
    }
}

private struct SyntheticForm: View {
    var body: some View {
        Form {
            Section {
                Toggle("Synthetic switch", isOn: .constant(true))
                Toggle("Another switch", isOn: .constant(false))
                LabeledContent("Synthetic value") { Text("Ready") }
            }
            Section {
                Toggle("Third switch", isOn: .constant(true))
                Toggle("Fourth switch", isOn: .constant(false))
            }
        }
        .settingsForm()
    }
}

@MainActor
@Suite(.serialized, .exclusiveScale)
struct PageSkeletonFrameTests {
    private static let tolerance = 2
    private static let settle = ContentActivityTiming.placeholderDelay + .milliseconds(600)

    private static func luminance(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Double {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    private static func headerFloor(_ variant: RenderCapture.Variant) async throws -> Int {
        let rendered = try await RenderCapture.render("skeleton-frame-header", variant: variant) {
            page { Color.clear.frame(height: 1) }
        }
        let bitmap = rendered.bitmap
        let scale = bitmap.pixelsWide / Int(bitmap.size.width)
        let background = luminance(bitmap, x: 1, y: bitmap.pixelsHigh - 2)
        var last = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: scale) {
            let inked = stride(from: 0, to: bitmap.pixelsWide, by: scale).contains {
                abs(luminance(bitmap, x: $0, y: y) - background) > 0.008
            }
            if inked { last = y / scale }
        }
        return last + 1
    }

    private static func page<Content: View>(
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        PageScaffold {
            PageHeader("Synthetic page", subtitle: "Synthetic subtitle for layout checks")
        } content: {
            content()
        }
    }

    private static func recipe(_ layout: PageSkeletonLayout, state: ContentLoadingState)
        -> some View
    {
        page {
            PageLoading(state: state, layout: layout, showsSkeletonControls: false) {
                SyntheticRecipeContent(layout: layout)
            }
        }
    }

    private static func compare(
        _ name: String, variant: RenderCapture.Variant, floor: Int,
        loading: () -> some View, content: () -> some View
    ) async throws {
        let skeleton = try await RenderCapture.render(
            "\(name)-loading", variant: variant, settle: settle
        ) {
            loading()
        }
        let loaded = try await RenderCapture.render("\(name)-content", variant: variant) {
            content()
        }
        let skeletonBounds = try #require(RenderCapture.inkBounds(skeleton.bitmap, below: floor))
        let loadedBounds = try #require(RenderCapture.inkBounds(loaded.bitmap, below: floor))
        let label = "\(name) \(variant.name): skeleton \(skeletonBounds), content \(loadedBounds)"
        #expect(abs(skeletonBounds.leading - loadedBounds.leading) <= tolerance, "\(label)")
        #expect(abs(skeletonBounds.trailing - loadedBounds.trailing) <= tolerance, "\(label)")
        #expect(abs(skeletonBounds.top - loadedBounds.top) <= tolerance, "\(label)")
    }

    @Test func pageRecipesOccupyTheirContentFrame() async throws {
        for variant in RenderCapture.variants {
            let floor = try await Self.headerFloor(variant)
            for layout in PageSkeletonLayout.allCases where layout != .form {
                try await Self.compare(
                    "skeleton-frame-\(layout)", variant: variant, floor: floor,
                    loading: { Self.recipe(layout, state: .loading) },
                    content: { Self.recipe(layout, state: .content) })
            }
        }
    }

    @Test func formRecipeOccupiesTheGroupedFormFrame() async throws {
        for variant in RenderCapture.variants {
            try await Self.compare(
                "skeleton-frame-form-page", variant: variant, floor: 0,
                loading: { PageSkeleton(layout: .form).pageSurface() },
                content: { SyntheticForm().pageSurface() })
            try await Self.compare(
                "skeleton-frame-form-column", variant: variant, floor: 0,
                loading: {
                    PageSkeleton(layout: .form)
                        .frame(maxWidth: UIScale.pt(PageMetrics.formWidth), maxHeight: .infinity)
                        .frame(maxWidth: .infinity).pageSurface()
                },
                content: {
                    SyntheticForm()
                        .frame(maxWidth: UIScale.pt(PageMetrics.formWidth), maxHeight: .infinity)
                        .frame(maxWidth: .infinity).pageSurface()
                })
        }
    }

    @Test func editorRecipeFillsAWorkspaceFromTheTop() async throws {
        let workspace = { (state: ContentLoadingState) in
            PageWorkspace {
                EmptyView()
            } content: {
                PageLoading(state: state, layout: .editor, showsSkeletonControls: false) {
                    PagePanel(fill: true) {
                        EmptyView()
                    } content: {
                        RoundedRectangle(cornerRadius: UIScale.pt(12)).fill(.secondary)
                    }
                }
            }
        }
        for variant in RenderCapture.variants {
            try await Self.compare(
                "skeleton-frame-workspace", variant: variant, floor: 0,
                loading: { workspace(.loading) }, content: { workspace(.content) })
        }
    }

    @Test func controlSettingsSkeletonOccupiesTheFormFrame() async throws {
        let settings = SyntheticFormSettings()
        let host = {
            ControlSettingsHost(presentation: settings) { SyntheticForm() }.pageSurface()
        }
        for variant in RenderCapture.variants {
            settings.load.reset()
            let loading = try await RenderCapture.render(
                "skeleton-frame-control-settings-loading", variant: variant, settle: Self.settle,
                content: host)
            settings.load.setContent()
            let loaded = try await RenderCapture.render(
                "skeleton-frame-control-settings-content", variant: variant, content: host)
            let skeletonBounds = try #require(RenderCapture.inkBounds(loading.bitmap))
            let loadedBounds = try #require(RenderCapture.inkBounds(loaded.bitmap))
            let label = "\(variant.name): skeleton \(skeletonBounds), content \(loadedBounds)"
            #expect(
                abs(skeletonBounds.leading - loadedBounds.leading) <= Self.tolerance, "\(label)")
            #expect(
                abs(skeletonBounds.trailing - loadedBounds.trailing) <= Self.tolerance, "\(label)")
            #expect(abs(skeletonBounds.top - loadedBounds.top) <= Self.tolerance, "\(label)")
        }
    }
}
