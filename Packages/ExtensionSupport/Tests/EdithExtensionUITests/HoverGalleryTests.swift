import AppKit
import EdithExtensionTestSupport
import SwiftUI
import Testing

@testable import EdithExtensionUI

@MainActor
@Suite(.serialized)
struct HoverGalleryTests {
    private func trackers(in view: NSView) -> Int {
        view.subviews.reduce(view is EdithHoverTrackingView ? 1 : 0) {
            $0 + trackers(in: $1)
        }
    }

    @Test func denseGridsSkipThePerControlTrackerAndOrdinaryButtonsKeepIt() async throws {
        var counts: [Bool: Int] = [:]
        for dense in [false, true] {
            let host = NSHostingView(
                rootView: VStack {
                    ForEach(0..<8, id: \.self) { index in
                        Button("Cell \(index)") {}.buttonStyle(.edith(.borderless))
                    }
                }
                .environment(\.edithDenseHover, dense))
            host.frame = CGRect(x: 0, y: 0, width: 240, height: 320)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host
            defer { window.contentView = nil }
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            counts[dense] = trackers(in: host)
        }
        #expect(counts[false] == 8)
        #expect(counts[true] == 0)
    }

    struct Folder: Identifiable {
        let id: String
        let path: String
    }

    static let folders = [
        Folder(id: "sample-app", path: "~/Work/sample-app"),
        Folder(id: "demo-service", path: "~/Work/clients/demo-service"),
        Folder(id: "notes-site", path: "~/Projects/notes-site"),
    ]

    nonisolated static let schemes: [ColorScheme] = [.light, .dark]
    static let states: [EdithInteractionPreview?] = [nil, .hovered, .pressed]

    private static func stateName(_ state: EdithInteractionPreview?) -> String {
        switch state {
        case nil: "rest"
        case .hovered?: "hover"
        case .pressed?: "press"
        }
    }

    @ViewBuilder
    private static func controls(_ state: EdithInteractionPreview?) -> some View {
        HStack(spacing: 14) {
            Text(stateName(state)).font(.edithText(.caption)).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Button("Primary") {}.buttonStyle(.edith(.primary))
            Button("Secondary") {}.buttonStyle(.edith(.secondary))
            Button("Delete") {}.buttonStyle(.edith(.destructive))
            Button("Borderless") {}.buttonStyle(.edith(.borderless))
            Button {
            } label: {
                EdithIconView(.search).frame(width: 20, height: 24)
            }
            .buttonStyle(.edith(.toolbar)).accessibilityLabel("Search")
            Button {
            } label: {
                EdithIconView(.plus).frame(width: 16, height: 16)
            }
            .buttonStyle(.edith(.iconOnly)).accessibilityLabel("Add")
            Button("Link") {}.buttonStyle(.edithLink)
            PageChip("Chip") {}
            Menu {
                Button("Item") {}
            } label: {
                Text("Menu")
            }
            .borderlessMenu().fixedSize()
            Menu {
                Button("Item") {}
            } label: {
                Text("Pull-down")
            }
            .menuStyle(.button).buttonStyle(.edith(.secondary)).fixedSize()
            PageMenuChip("Filter") { Button("Item") {} }
            EdithSplitButton(.secondary, menuAccessibilityLabel: "More") {
            } label: {
                Text("Split")
            } menu: {
                Button("Item") {}
            }
        }
        .environment(\.edithInteractionPreview, state)
    }

    @ViewBuilder
    private static func shaped(_ state: EdithInteractionPreview?, labeled: Bool = true) -> some View
    {
        HStack(spacing: 18) {
            Text(labeled ? stateName(state) : "").font(.edithText(.caption))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Button {
            } label: {
                EdithIconView(.play).foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.tint, in: Circle())
            }
            .buttonStyle(.edithShaped(Circle(), filled: true))
            .accessibilityLabel("Play")
            Button {
            } label: {
                EdithIconView(.rewind).frame(width: 34, height: 34)
            }
            .buttonStyle(.edithShaped(Circle()))
            .accessibilityLabel("Previous")
            Button {
            } label: {
                Text("Install").foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.tint, in: Capsule())
            }
            .buttonStyle(.edithShaped(Capsule(), filled: true))
            Button {
            } label: {
                Text("3 ports").padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.orange.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.edithShaped(Capsule()))
            Button {
            } label: {
                LinearGradient(
                    colors: [.indigo, .pink], startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(
                .edithShaped(RoundedRectangle(cornerRadius: 6, style: .continuous), filled: true)
            )
            .accessibilityLabel("Artwork")
            Button {
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Slow Orbit").font(.edithText(.body).weight(.semibold))
                    Text("Paused").font(.edithText(.subheadline)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.edithBlock)
        }
        .environment(\.edithInteractionPreview, state)
    }

    @ViewBuilder
    private static func fields(_ state: EdithInteractionPreview?, labeled: Bool = true)
        -> some View
    {
        HStack(spacing: 18) {
            Text(labeled ? stateName(state) : "").font(.edithText(.caption))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Toggle("Switch", isOn: .constant(true)).toggleStyle(.edithSwitch).labelsHidden()
            Toggle("Off", isOn: .constant(false)).toggleStyle(.edithSwitch).labelsHidden()
            Toggle("Checkbox", isOn: .constant(true)).toggleStyle(.edithCheckbox)
            EdithSegmentedPicker(
                "Range", selection: .constant("Week"), options: ["Day", "Week", "Month"],
                label: { $0 }
            )
            .frame(width: 200)
            Slider(value: .constant(0.4)).frame(width: 110)
            Stepper("Count", value: .constant(3)).labelsHidden()
            EdithTextField(placeholder: "Field", text: .constant("")).frame(width: 110)
            SearchField(placeholder: "Search", text: .constant("")).frame(width: 130)
        }
        .environment(\.edithInteractionPreview, state)
    }

    private static func folderList(hovered: String?) -> some View {
        EdithRowList(folders) { folder in
            EdithRowButton {
            } label: {
                HStack(spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                    EdithIconView(.folder).font(.edithText(.title2).weight(.medium))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.id).font(.edithText(.headline))
                        Text(folder.path).font(.edithText(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } accessory: {
                Text("2 worktrees").font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            .environment(\.edithInteractionPreview, folder.id == hovered ? .hovered : nil)
        }
        .frame(width: 520)
    }

    @Test(arguments: schemes)
    func galleryCapturesEveryControlAtRestHoverAndPress(scheme: ColorScheme) async throws {
        let name = scheme == .dark ? "dark" : "light"
        let rendered = try await RenderCapture.render(
            "hover-gallery",
            variant: .init(name: name, width: 1320, height: 960, zoom: 1, scheme: scheme)
        ) {
            VStack(alignment: .leading, spacing: 22) {
                PageCapsLabel("Buttons and menus")
                ForEach(Self.states.indices, id: \.self) { Self.controls(Self.states[$0]) }
                PageCapsLabel("Self-shaped controls follow their own shape")
                ForEach(Self.states.indices, id: \.self) { Self.shaped(Self.states[$0]) }
                PageCapsLabel(
                    "Toggles, checkboxes, segments, sliders, steppers and fields never show a plate"
                )
                ForEach(Self.states.indices, id: \.self) { Self.fields(Self.states[$0]) }
                PageCapsLabel("Rows fill their cell")
                HStack(alignment: .top, spacing: 24) {
                    Self.folderList(hovered: nil)
                    Self.folderList(hovered: "demo-service")
                }
            }
            .padding(28)
        }
        #expect(RenderCapture.distinctColors(rendered.bitmap) > 8)
    }

    private func render<V: View>(_ name: String, scheme: ColorScheme, size: CGSize, _ view: V)
        async throws -> NSBitmapImageRep
    {
        try await RenderCapture.render(
            name,
            variant: .init(
                name: scheme == .dark ? "dark" : "light", width: size.width, height: size.height,
                zoom: 1, scheme: scheme)
        ) {
            view.padding(20)
        }
        .bitmap
    }

    private func changedBounds(
        _ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep, in rect: CGRect? = nil
    ) -> CGRect? {
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min
        let unit = CGFloat(lhs.pixelsWide) / lhs.size.width
        let area =
            rect.map {
                CGRect(
                    x: $0.minX * unit, y: $0.minY * unit, width: $0.width * unit,
                    height: $0.height * unit)
            } ?? CGRect(x: 0, y: 0, width: lhs.pixelsWide, height: lhs.pixelsHigh)
        for x in Int(area.minX)..<min(Int(area.maxX), lhs.pixelsWide, rhs.pixelsWide) {
            for y in Int(area.minY)..<min(Int(area.maxY), lhs.pixelsHigh, rhs.pixelsHigh) {
                guard let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let distance =
                    abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                guard distance > 0.02 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard minX != .max else { return nil }
        let scale = CGFloat(lhs.pixelsWide) / lhs.size.width
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    private func inkBounds(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> CGRect? {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let luminance = { (x: Int, y: Int) -> CGFloat in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        let fill = luminance(Int((rect.minX + 3) * scale), Int(rect.midY * scale))
        var minX = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var minY = CGFloat.infinity
        var maxY = -CGFloat.infinity
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            for y in Int(rect.minY * scale)..<Int(rect.maxY * scale)
            where abs(luminance(x, y) - fill) > 0.15 {
                minX = min(minX, CGFloat(x) / scale)
                maxX = max(maxX, CGFloat(x + 1) / scale)
                minY = min(minY, CGFloat(y) / scale)
                maxY = max(maxY, CGFloat(y + 1) / scale)
            }
        }
        guard minX.isFinite else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    @Test(arguments: schemes)
    func togglesCheckboxesAndSegmentsNeverDrawAPlate(scheme: ColorScheme) async throws {
        let size = CGSize(width: 1100, height: 80)
        let idle = try await render(
            "hover-fields", scheme: scheme, size: size, Self.fields(nil, labeled: false))
        let hovered = try await render(
            "hover-fields-hovered", scheme: scheme, size: size,
            Self.fields(.hovered, labeled: false))
        let changed = changedBounds(idle, hovered)
        #expect(changed == nil, "\(String(describing: changed))")
    }

    @Test(arguments: schemes)
    func rowPlateFillsTheCellMinusTheKitInset(scheme: ColorScheme) async throws {
        let size = CGSize(width: 560, height: 260)
        let idle = try await render(
            "hover-rows", scheme: scheme, size: size, Self.folderList(hovered: nil))
        let hovered = try await render(
            "hover-rows-hovered", scheme: scheme, size: size,
            Self.folderList(hovered: "demo-service"))
        let changed = try #require(changedBounds(idle, hovered))
        let listWidth = 520.0
        let probe = NSHostingView(
            rootView: Self.folderList(hovered: nil).fixedSize(horizontal: false, vertical: true))
        let listHeight = probe.fittingSize.height
        let cellHeight = (listHeight - 2) / 3
        let cell = CGRect(x: 20, y: 20 + cellHeight + 1, width: listWidth, height: cellHeight)
        let plate = EdithRowMetrics.plateFrame(cell: cell)
        #expect(abs(changed.minX - plate.minX) <= 1, "\(changed) vs \(plate)")
        #expect(abs(changed.maxX - plate.maxX) <= 1, "\(changed) vs \(plate)")
        #expect(changed.minY <= plate.minY + 1, "\(changed) vs \(plate)")
        #expect(changed.maxY >= plate.maxY - 1, "\(changed) vs \(plate)")
        #expect(changed.minY >= cell.minY - 1.5, "\(changed) vs \(cell)")
        #expect(changed.maxY <= cell.maxY + 1.5, "\(changed) vs \(cell)")
        let content = EdithRowMetrics.contentFrame(cell: cell)
        let ink = try #require(inkBounds(idle, in: plate))
        #expect(ink.minX >= content.minX - 1, "\(ink) vs \(content)")
        #expect(ink.maxX <= content.maxX + 1, "\(ink) vs \(content)")
        #expect(ink.minY >= plate.minY, "\(ink) vs \(plate)")
        #expect(ink.maxY <= plate.maxY, "\(ink) vs \(plate)")
    }

    @Test(arguments: schemes)
    func unstyledButtonsKeepTheNativeLookAndGainAPlate(scheme: ColorScheme) async throws {
        let size = CGSize(width: 420, height: 80)
        let native = HStack(spacing: 16) {
            Button("Native") {}
            Button("Default") {}.keyboardShortcut(.defaultAction)
            Button("Small") {}.controlSize(.small)
        }
        let wrapped = try await render(
            "hover-default-rest", scheme: scheme, size: size, native)
        let automatic = try await render(
            "hover-default-automatic", scheme: scheme, size: size,
            native.buttonStyle(.automatic))
        #expect(changedBounds(wrapped, automatic) == nil)
        let hovered = try await render(
            "hover-default-hovered", scheme: scheme, size: size,
            native.environment(\.edithInteractionPreview, .hovered))
        #expect(changedBounds(wrapped, hovered) != nil)
    }

    @Test(arguments: schemes)
    func circleControlsNeverPaintOutsideTheCircle(scheme: ColorScheme) async throws {
        let size = CGSize(width: 900, height: 80)
        let idle = try await render(
            "hover-shaped", scheme: scheme, size: size, Self.shaped(nil, labeled: false))
        let hovered = try await render(
            "hover-shaped-hovered", scheme: scheme, size: size,
            Self.shaped(.hovered, labeled: false))
        let pressed = try await render(
            "hover-shaped-pressed", scheme: scheme, size: size,
            Self.shaped(.pressed, labeled: false))
        #expect(changedBounds(idle, hovered) != nil)
        #expect(changedBounds(hovered, pressed) != nil)
        let circleLeft = 20.0 + 44 + 18
        let circleTop = 20.0
        let corners = [
            CGRect(x: circleLeft, y: circleTop, width: 4, height: 4),
            CGRect(x: circleLeft + 38, y: circleTop, width: 4, height: 4),
            CGRect(x: circleLeft, y: circleTop + 38, width: 4, height: 4),
            CGRect(x: circleLeft + 38, y: circleTop + 38, width: 4, height: 4),
        ]
        for corner in corners {
            #expect(changedBounds(idle, hovered, in: corner) == nil, "\(corner)")
        }
    }

    @Test func nativeMenusKeepTheirLookWithTheDefaultStyle() async throws {
        let native = Menu("Actions") { Button("Item") {} }.fixedSize()
        let rest = try await render(
            "hover-default-menu-native", scheme: .light, size: CGSize(width: 200, height: 70),
            native)
        let styled = try await render(
            "hover-default-menu-styled", scheme: .light, size: CGSize(width: 200, height: 70),
            native.menuStyle(.button).buttonStyle(.edithDefault))
        #expect(RenderCapture.distinctColors(rest) > 1)
        #expect(changedBounds(rest, styled) == nil)
    }

    @Test func rowPlateLeavesLayoutUntouched() {
        let resting = NSHostingView(rootView: Self.folderList(hovered: nil)).fittingSize
        let lit = NSHostingView(rootView: Self.folderList(hovered: "sample-app")).fittingSize
        #expect(resting == lit)
    }

    @Test func pointerMovementLightsButtons() async throws {
        try await pointerLights(crossings: true)
    }

    @Test func buttonsLightWhenTheHostingViewMissedItsMouseEntered() async throws {
        try await pointerLights(crossings: false)
    }

    private func pointerLights(crossings: Bool) async throws {
        let host = NSHostingView(
            rootView: HStack(spacing: 24) {
                Button {
                } label: {
                    EdithIconView(.search).frame(width: 20, height: 24)
                }
                .buttonStyle(.edith(.toolbar))
                Button("Borderless") {}.buttonStyle(.edith(.borderless))
                Text("Highlight").padding(6).edithHoverHighlight()
            }
            .padding(30)
            .frame(width: 360, height: 100, alignment: .topLeading)
            .environment(\.colorScheme, .light)
            .transaction { $0.animation = nil })
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 100)
        let window = PointerSimulation.window(contentRect: host.frame)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let snapshot = { () -> NSBitmapImageRep in
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }
        let idle = snapshot()
        for point in [CGPoint(x: 46, y: 46), CGPoint(x: 120, y: 46), CGPoint(x: 240, y: 46)] {
            PointerSimulation.move(to: point, in: host, window: window, crossings: crossings)
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let lit = try #require(changedBounds(idle, snapshot()), "\(point)")
            #expect(lit.contains(point), "\(point) lit \(lit)")
            PointerSimulation.leave(window)
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            #expect(changedBounds(idle, snapshot()) == nil, "\(point) stays lit")
        }
    }
}
