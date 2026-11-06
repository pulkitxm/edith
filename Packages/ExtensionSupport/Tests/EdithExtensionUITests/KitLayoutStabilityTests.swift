import AppKit
import EdithExtensionCore
import EdithExtensionTestSupport
import SwiftUI
import Testing

@testable import EdithExtensionUI

@MainActor private final class RowProbe {
    var frames: [String: CGRect] = [:]
}

private extension View {
    func probed(_ name: String, into probe: RowProbe) -> some View {
        onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            probe.frames[name] = $0
        }
    }
}

@MainActor @Suite(.serialized, .exclusiveScale) struct SettingsFormRowTests {
    private struct Rows: View {
        let probe: RowProbe
        @State private var on = true
        @State private var choice = 1
        @State private var text = ""

        var body: some View {
            Form {
                Section {
                    LabeledContent {
                        Color.red.frame(width: 40, height: 22).probed("control", into: probe)
                    } label: {
                        Text("Keep running with lid closed").probed("title", into: probe)
                        Text(String(repeating: "A long detail that wraps. ", count: 8))
                            .probed("detail", into: probe)
                    }
                    Toggle(isOn: $on) {
                        Text("Keep running with lid closed")
                        Text(String(repeating: "A long detail that wraps. ", count: 8))
                    }
                    Toggle(isOn: $on) { Text("Single line") }
                    Picker(selection: $choice) {
                        Text("One").tag(1)
                        Text("Two").tag(2)
                    } label: {
                        Text("How long")
                        Text("Turns itself off after this.")
                    }
                    Slider(value: .constant(0.5)) {
                        Text("Slider")
                        Text("A subtitle under the slider.")
                    }
                    LabeledContent {
                        EmptyView()
                    } label: {
                        Text("Native row")
                        Text("With a subtitle")
                    }
                    SettingsRow("Settings row", subtitle: "With a subtitle") {
                        Toggle("", isOn: $on).labelsHidden()
                    }
                    SettingsNoticeRow("Notice row", message: "A message beneath the notice.")
                    LabeledContent("Value row", value: "Value")
                    TextField("Name", text: $text, prompt: Text("Placeholder"))
                    Picker("Hidden label", selection: $choice) {
                        Text("Hidden label choice").tag(1)
                        Text("Two").tag(2)
                    }
                    .labelsHidden()
                    .probed("hidden", into: probe)
                }
            }
            .settingsForm()
            .probed("form", into: probe)
        }
    }

    @Test func controlsCenterOnTheirLabelsAcrossLines() async throws {
        let probe = RowProbe()
        try await RenderCapture.render("settings-form-rows", variant: RenderCapture.variants[0]) {
            Rows(probe: probe)
        }
        let control = try #require(probe.frames["control"])
        let title = try #require(probe.frames["title"])
        let detail = try #require(probe.frames["detail"])
        #expect(detail.height > title.height * 1.5)
        #expect(abs(control.midY - (title.minY + detail.maxY) / 2) <= 1)
    }

    @Test func aHiddenLabelLeavesTheControlTheWholeRow() async throws {
        let probe = RowProbe()
        try await RenderCapture.render("settings-form-rows", variant: RenderCapture.variants[0]) {
            Rows(probe: probe)
        }
        let form = try #require(probe.frames["form"])
        let hidden = try #require(probe.frames["hidden"])
        #expect(hidden.minX < form.midX)
    }
}

@MainActor @Suite(.serialized, .exclusiveScale) struct SearchFieldStabilityTests {
    private struct Field: View {
        let compact: Bool
        let text: String
        var body: some View {
            SearchField(placeholder: "Search", text: .constant(text), compact: compact)
                .frame(width: 240)
        }
    }

    @Test(arguments: [false, true]) func theClearButtonLeavesTheHeightAlone(compact: Bool) {
        let empty = NSHostingView(rootView: Field(compact: compact, text: "")).fittingSize
        let typed = NSHostingView(rootView: Field(compact: compact, text: "typed")).fittingSize
        #expect(empty.height == typed.height)
    }
}

@MainActor @Suite(.serialized, .exclusiveScale) struct PageViewportCenteringTests {
    private func marks(_ pinned: Bool) async throws -> (
        block: CGRect, header: CGRect, height: Double
    ) {
        let probe = RowProbe()
        let variant = RenderCapture.Variant(
            name: "viewport-\(pinned)", width: 900, height: 700, zoom: 1, scheme: .light)
        try await RenderCapture.render("page-viewport", variant: variant) {
            PageScaffold(pinnedHeader: pinned) {
                PageHeader("Header").probed("header", into: probe)
            } content: {
                Color.red.frame(width: 80, height: 80)
                    .probed("block", into: probe)
                    .pageFillViewport()
            }
        }
        return (
            try #require(probe.frames["block"]), try #require(probe.frames["header"]), 700
        )
    }

    @Test(arguments: [true, false]) func fillStatesCenterBelowTheHeader(pinned: Bool) async throws {
        let (block, header, height) = try await marks(pinned)
        #expect(abs(block.midY - (header.maxY + height) / 2) <= 1)
    }

    @Test func contentTallerThanTheViewportKeepsItsTopEdge() async throws {
        let probe = RowProbe()
        let variant = RenderCapture.Variant(
            name: "viewport-tall", width: 900, height: 400, zoom: 1, scheme: .light)
        try await RenderCapture.render("page-viewport", variant: variant) {
            PageScaffold(pinnedHeader: true) {
                PageHeader("Header").probed("header", into: probe)
            } content: {
                Color.red.frame(width: 80, height: 700)
                    .probed("block", into: probe)
                    .pageFillViewport()
            }
        }
        let block = try #require(probe.frames["block"])
        let header = try #require(probe.frames["header"])
        #expect(abs(block.minY - header.maxY - PageMetrics.pinnedContentTop) <= 1)
    }
}

@MainActor @Suite(.serialized, .exclusiveScale) struct WorldClockAlignmentTests {
    private func topInk(_ bitmap: NSBitmapImageRep, columns: Range<Int>) -> Int? {
        let scale = bitmap.pixelsWide / Int(bitmap.size.width)
        let luminance = { (x: Int, y: Int) -> Double in
            guard
                let color = bitmap.colorAt(x: x * scale, y: y * scale)?
                    .usingColorSpace(.deviceRGB)
            else { return 0 }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        let background = luminance(2, 2)
        return (0..<Int(bitmap.size.height)).first { row in
            columns.contains { abs(luminance($0, row) - background) > 0.02 }
        }
    }

    @Test func theAddTileLinesUpWithTheClockFaces() async throws {
        let suite = "surface-clocks-alignment." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Asia/Kolkata,Asia/Tokyo", forKey: AppStorageKeys.General.homeClockZones)
        var tile = SurfaceTile(.clocks)
        tile.itemLimit = 4
        tile.showActions = true
        let variant = RenderCapture.Variant(
            name: "alignment", width: 900, height: 300, zoom: 1, scheme: .light)
        let rendered = try await RenderCapture.render("world-clocks", variant: variant) {
            SurfaceWorldClocks(tile: tile, defaults: defaults)
        }
        let face = try #require(topInk(rendered.bitmap, columns: 0..<450))
        let add = try #require(topInk(rendered.bitmap, columns: 680..<900))
        #expect(abs(face - add) <= 1)
    }
}
