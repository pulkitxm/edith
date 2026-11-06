import AppKit
import EdithExtensionTestSupport
import SwiftUI
import Testing

@testable import EdithExtensionUI

@MainActor
@Suite(.serialized)
struct SplitButtonRenderingTests {
    nonisolated static let schemes: [ColorScheme] = [.dark, .light]

    struct Probe {
        let bitmap: NSBitmapImageRep
        let scale: Int

        init(_ bitmap: NSBitmapImageRep) {
            self.bitmap = bitmap
            scale = max(1, bitmap.pixelsWide / max(1, Int(bitmap.size.width)))
        }

        func luminance(_ x: Int, _ y: Int) -> Double {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                return 0
            }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }

        var background: Double { luminance(1, 1) }

        func differs(_ x: Int, _ y: Int, from reference: Double, by threshold: Double = 0.012)
            -> Bool
        {
            abs(luminance(x, y) - reference) > threshold
        }

        func columnExtent(_ x: Int) -> ClosedRange<Int>? {
            let rows = (0..<bitmap.pixelsHigh).filter { differs(x, $0, from: background) }
            guard let first = rows.first, let last = rows.last else { return nil }
            return first...last
        }

        func rowExtent(_ y: Int) -> ClosedRange<Int>? {
            let columns = (0..<bitmap.pixelsWide).filter { differs($0, y, from: background) }
            guard let first = columns.first, let last = columns.last else { return nil }
            return first...last
        }

        func changedRows(_ x: Int, against other: Probe) -> ClosedRange<Int>? {
            let rows = (0..<bitmap.pixelsHigh).filter {
                abs(luminance(x, $0) - other.luminance(x, $0)) > 0.008
            }
            guard let first = rows.first, let last = rows.last else { return nil }
            return first...last
        }
    }

    static func string(_ object: NSObject, _ selector: String) -> String? {
        let getter = NSSelectorFromString(selector)
        guard object.responds(to: getter) else { return nil }
        let value = object.perform(getter)?.takeUnretainedValue()
        return (value as? String) ?? (value as? NSAttributedString)?.string
    }

    static func element(in root: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if string(root, "accessibilityLabel") == label
            || string(root, "accessibilityTitle") == label
        {
            return root
        }
        for child in (root as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let found = element(in: child, label: label, depth: depth + 1) { return found }
        }
        return nil
    }

    private func button(disabled: Bool = false) -> some View {
        EdithSplitButton(
            "Synthetic", actionAccessibilityLabel: "Run synthetic",
            menuAccessibilityLabel: "Synthetic alternatives"
        ) {
        } menu: {
            Button("Alternative", edith: .terminal) {}
        }
        .disabled(disabled)
    }

    private func render(
        _ name: String, scheme: ColorScheme, preview: EdithInteractionPreview? = nil,
        disabled: Bool = false, inspect: (NSView) throws -> Void = { _ in }
    ) async throws -> RenderCapture.Rendered {
        try await RenderCapture.render(
            name,
            variant: .init(
                name: scheme == .dark ? "dark" : "light", width: 220, height: 72, zoom: 1,
                scheme: scheme),
            inspect: inspect
        ) {
            button(disabled: disabled)
                .environment(\.edithInteractionPreview, preview)
                .padding(20)
        }
    }

    @Test(arguments: schemes)
    func drawsOneJoinedContainerWithADivider(scheme: ColorScheme) async throws {
        try await RenderCapture.withAccessibility {
            var actionFrame = CGRect.zero
            var menuFrame = CGRect.zero
            let rendered = try await render("split-button", scheme: scheme) { host in
                let action = try #require(Self.element(in: host, label: "Run synthetic"))
                let menu = try #require(Self.element(in: host, label: "Synthetic alternatives"))
                actionFrame = (action as AnyObject).accessibilityFrame?() ?? .zero
                menuFrame = (menu as AnyObject).accessibilityFrame?() ?? .zero
            }
            let probe = Probe(rendered.bitmap)
            let scale = probe.scale
            #expect(actionFrame.height > 0 && menuFrame.height > 0)
            #expect(abs(actionFrame.height - menuFrame.height) < 0.5, "\(actionFrame) \(menuFrame)")
            #expect(abs(actionFrame.minY - menuFrame.minY) < 0.5)
            #expect(abs(menuFrame.width - EdithSplitButtonMetrics.menuWidth) < 0.5)
            #expect(abs(menuFrame.width - menuFrame.height) < 0.5)
            #expect(menuFrame.minX - actionFrame.maxX >= 0)
            #expect(menuFrame.minX - actionFrame.maxX <= 1.01)

            let top = 20 * scale
            let height = Int(actionFrame.height) * scale
            let bandRow = top + height / 4
            let extent = try #require(probe.rowExtent(bandRow))
            let totalWidth = Int((menuFrame.maxX - actionFrame.minX).rounded()) * scale
            #expect(abs(extent.lowerBound - 20 * scale) <= scale)
            #expect(abs(extent.count - totalWidth) <= 2 * scale, "\(extent) \(totalWidth)")
            #expect(
                extent.allSatisfy { probe.differs($0, bandRow, from: probe.background, by: 0.008) },
                "a page-colored gap splits the control")

            let fill = probe.luminance(extent.lowerBound + 4 * scale, bandRow)
            let inner = (extent.lowerBound + 3 * scale)...(extent.upperBound - 3 * scale)
            let divider = inner.filter { probe.differs($0, bandRow, from: fill, by: 0.01) }
            let expectedDivider =
                extent.upperBound + 1 - Int(EdithSplitButtonMetrics.menuWidth) * scale
            #expect(!divider.isEmpty, "no divider")
            #expect(divider.count <= 2 * scale, "\(divider)")
            #expect(divider.allSatisfy { abs($0 - expectedDivider) <= 2 * scale }, "\(divider)")

            let actionColumn = extent.lowerBound + 6 * scale
            let menuColumn = extent.upperBound - 6 * scale
            let actionExtent = try #require(probe.columnExtent(actionColumn))
            let menuExtent = try #require(probe.columnExtent(menuColumn))
            #expect(actionExtent == menuExtent, "\(actionExtent) \(menuExtent)")
            #expect(abs(actionExtent.count - height) <= scale)

            let borderRow = actionExtent.lowerBound
            let borderSpan = (extent.lowerBound + 8 * scale)...(extent.upperBound - 8 * scale)
            #expect(
                borderSpan.allSatisfy {
                    probe.differs($0, borderRow, from: probe.background, by: 0.008)
                },
                "the outer border breaks between segments")
        }
    }

    @Test(arguments: schemes)
    func hoverPlatesCoverEachSegmentToTheSameHeight(scheme: ColorScheme) async throws {
        let idle = Probe(try await render("split-button-idle", scheme: scheme).bitmap)
        let hovered = Probe(
            try await render("split-button-hovered", scheme: scheme, preview: .hovered).bitmap)
        let pressed = Probe(
            try await render("split-button-pressed", scheme: scheme, preview: .pressed).bitmap)
        let scale = idle.scale
        let extent = try #require(idle.rowExtent(20 * scale + 6 * scale))
        let actionColumn = extent.lowerBound + 6 * scale
        let menuColumn = extent.upperBound - 6 * scale
        let actionHover = try #require(hovered.changedRows(actionColumn, against: idle))
        let menuHover = try #require(hovered.changedRows(menuColumn, against: idle))
        #expect(actionHover == menuHover, "\(actionHover) \(menuHover)")
        #expect(hovered.changedRows(menuColumn, against: pressed) != nil)
        let disabledIdle = Probe(
            try await render("split-button-disabled", scheme: scheme, disabled: true).bitmap)
        let disabledHover = Probe(
            try await render(
                "split-button-disabled-hovered", scheme: scheme, preview: .hovered, disabled: true
            ).bitmap)
        #expect(disabledHover.changedRows(actionColumn, against: disabledIdle) == nil)
        #expect(disabledHover.changedRows(menuColumn, against: disabledIdle) == nil)
        #expect(idle.changedRows(actionColumn, against: disabledIdle) != nil)
    }

    @Test func scalesWithZoom() {
        let scale = UIScale.current
        defer { UIScale.apply(scale) }
        var widths: [Double] = []
        for zoom in [1.0, 1.6] {
            UIScale.apply(zoom)
            let host = NSHostingView(
                rootView: button().fixedSize()
                    .environment(\.automaticViewActionsEnabled, false))
            let size = host.fittingSize
            #expect(size.height >= EdithSplitButtonMetrics.button.minimumHeight * zoom - 0.5)
            widths.append(size.width)
        }
        #expect(widths[1] > widths[0] * 1.4)
    }
}
