import AppKit
import EdithExtensionCore
import EdithExtensionTestSupport
import SwiftUI
import Testing

@testable import EdithExtensionUI

private struct ThemedRow: Identifiable {
    let id: Int
}

@MainActor @Suite(.serialized) struct ThemedControlsTests {
    private func withTheme(_ theme: AppTheme, _ body: () async throws -> Void) async throws {
        let defaults = ExtensionScope.process.defaults()
        let stored = defaults.string(forKey: AppStorageKeys.General.theme)
        _ = ThemeStore.current
        defaults.set(theme.rawValue, forKey: AppStorageKeys.General.theme)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while ThemeStore.current != theme, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        defer {
            if let stored {
                defaults.set(stored, forKey: AppStorageKeys.General.theme)
            } else {
                defaults.removeObject(forKey: AppStorageKeys.General.theme)
            }
        }
        #expect(ThemeStore.current == theme)
        try await body()
    }

    @discardableResult
    private func rendered(
        _ name: String, dark: Bool = false, width: Double = 320, height: Double = 180,
        @ViewBuilder content: () -> some View
    ) async throws -> NSBitmapImageRep {
        let stacked = VStack(spacing: 0, content: content)
        let variant = RenderCapture.Variant(
            name: dark ? "dark" : "light", width: width, height: height, zoom: 1,
            scheme: dark ? .dark : .light)
        let host = try await RenderCapture.render(name, variant: variant) { stacked }
        return host.bitmap
    }

    private func pixel(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        (bitmap.colorAt(x: x, y: y) ?? .black).usingColorSpace(.sRGB) ?? .black
    }

    private static func swatch(_ theme: AppTheme, dark: Bool) -> some View {
        Rectangle().fill(Color(theme.accentNSColor(dark: dark)))
    }

    private func contains(
        _ color: NSColor, in bitmap: NSBitmapImageRep, above: Int? = nil,
        tolerance: CGFloat = 0.02
    ) -> Bool {
        let wanted = color.usingColorSpace(.sRGB) ?? .black
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 1) {
            for y in stride(from: 0, to: above ?? bitmap.pixelsHigh, by: 1) {
                let found = pixel(bitmap, x, y)
                if abs(found.redComponent - wanted.redComponent) < tolerance,
                    abs(found.greenComponent - wanted.greenComponent) < tolerance,
                    abs(found.blueComponent - wanted.blueComponent) < tolerance
                {
                    return true
                }
            }
        }
        return false
    }

    @Test func switchMatchesNativeProportionsAtEveryControlSize() {
        let native = [
            (ControlSize.mini, 36.0, 16.0), (.small, 44, 20), (.regular, 54, 24), (.large, 64, 28),
            (.extraLarge, 80, 36),
        ]
        for (size, width, height) in native {
            let metrics = EdithSwitchMetrics.metrics(for: size)
            #expect(metrics.width == width)
            #expect(metrics.height == height)
            #expect(metrics.knobWidth + metrics.inset * 2 < metrics.width)
        }
    }

    @Test func switchSizesToItsControlSizeWithHiddenLabels() {
        for size in [ControlSize.mini, .small, .regular, .large, .extraLarge] {
            let host = NSHostingView(
                rootView: Toggle("Hidden", isOn: .constant(true))
                    .labelsHidden().toggleStyle(.edithSwitch).controlSize(size))
            let metrics = EdithSwitchMetrics.metrics(for: size)
            #expect(host.fittingSize == CGSize(width: metrics.width, height: metrics.height))
        }
    }

    @Test func switchUsesTheThemeAccentInBothSchemesAndEveryWindowState() async throws {
        for theme in AppTheme.allCases {
            try await withTheme(theme) {
                for dark in [false, true] {
                    for state in [ControlActiveState.key, .inactive] {
                        let bitmap = try await rendered("switch-\(theme.rawValue)", dark: dark) {
                            Toggle("On", isOn: .constant(true))
                                .labelsHidden().toggleStyle(.edithSwitch)
                                .environment(\.controlActiveState, state)
                                .padding(20)
                                .frame(width: 320, height: 90, alignment: .topLeading)
                            Self.swatch(theme, dark: dark).frame(width: 320, height: 90)
                        }
                        let reference = pixel(bitmap, 40, bitmap.pixelsHigh - 20)
                        #expect(contains(reference, in: bitmap, above: bitmap.pixelsHigh / 2))
                    }
                }
            }
        }
    }

    @Test func switchReachesAccessibilityAsANativeSwitch() async throws {
        try await RenderCapture.withAccessibility {
            var isOn = false
            let binding = Binding(get: { isOn }, set: { isOn = $0 })
            let rendered = try await RenderCapture.render(
                "switch-accessibility", variant: RenderCapture.variants[0]
            ) {
                VStack {
                    Toggle("Keep the screen awake", isOn: binding).toggleStyle(.edithSwitch)
                    Toggle("", isOn: .constant(false)).labelsHidden().toggleStyle(.edithSwitch)
                        .accessibilityLabel("Hidden label")
                    Toggle("Titled", isOn: .constant(false)).toggleStyle(.edithSwitch)
                        .accessibilityLabel("Replaced title")
                    Toggle(isOn: .constant(false)) {
                        Text("Headline")
                        Text("Detail")
                    }
                    .labelsHidden().toggleStyle(.edithSwitch)
                }.padding()
            }
            #expect(RenderCapture.find(rendered.host, label: "Hidden label") != nil)
            #expect(RenderCapture.find(rendered.host, label: "Replaced title") != nil)
            #expect(RenderCapture.find(rendered.host, label: "Headline, Detail") != nil)
            let element = try #require(
                RenderCapture.find(rendered.host, label: "Keep the screen awake"))
            #expect((element as AnyObject).accessibilityRole?() == .checkBox)
            #expect((element as AnyObject).accessibilityPerformPress?() == true)
            #expect(isOn)
        }
    }

    @Test func settingsRowExposesItsTitleAsTheLabelAndItsSubtitleAsTheHint() async throws {
        try await RenderCapture.withAccessibility {
            let rendered = try await RenderCapture.render(
                "settings-row-accessibility", variant: RenderCapture.variants[0]
            ) {
                Form {
                    SettingsShortcutRow(
                        keyPrefix: "kitRowProbe", defaultLabel: "K", purpose: "Runs the probe.")
                }.settingsForm()
            }
            let element = try #require(
                RenderCapture.find(rendered.host, label: "Keyboard shortcut"))
            let hint = (element as AnyObject).accessibilityHelp?()
            #expect(hint?.hasPrefix("Runs the probe.") == true)
        }
    }

    @Test func groupedFormTogglesAdoptTheThemedSwitch() async throws {
        try await withTheme(.teal) {
            let bitmap = try await rendered("form-switch", dark: true) {
                Form {
                    Toggle("Automatic", isOn: .constant(true))
                }.edithForm().frame(width: 320, height: 90)
                Self.swatch(.teal, dark: true).frame(width: 320, height: 90)
            }
            let reference = pixel(bitmap, 40, bitmap.pixelsHigh - 20)
            #expect(contains(reference, in: bitmap, above: bitmap.pixelsHigh / 2))
        }
    }

    @Test func themedControlsFollowsTheStoreWhileMounted() async throws {
        try await withTheme(.teal) {
            let probe = NSHostingView(
                rootView: Rectangle().fill(.tint).themedControls()
                    .frame(width: 40, height: 40))
            probe.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
            let window = TestWindowHost.window(contentRect: probe.frame)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = probe
            window.orderBack(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            @MainActor func sample() throws -> NSColor {
                probe.layoutSubtreeIfNeeded()
                let bitmap = try #require(probe.bitmapImageRepForCachingDisplay(in: probe.bounds))
                probe.cacheDisplay(in: probe.bounds, to: bitmap)
                return pixel(bitmap, 10, 10)
            }
            try await Task.sleep(for: .milliseconds(100))
            let first = try sample()
            ExtensionScope.process.defaults().set(
                AppTheme.pink.rawValue, forKey: AppStorageKeys.General.theme)
            try await Task.sleep(for: .milliseconds(300))
            let second = try sample()
            #expect(abs(first.greenComponent - second.greenComponent) > 0.2)
        }
    }

    @Test func linkUsesTheThemeAccent() async throws {
        try await withTheme(.teal) {
            let bitmap = try await rendered("link") {
                VStack(spacing: 12) {
                    EdithLink(
                        "Open the release notes on the web",
                        destination: URL(string: "https://example.com")!
                    ).font(.system(size: 22, weight: .bold))
                    Button("Clear", action: {}).buttonStyle(.edithLink)
                        .font(.system(size: 22, weight: .bold))
                }.padding(10).frame(width: 320, height: 90, alignment: .topLeading)
                Self.swatch(.teal, dark: false).frame(width: 320, height: 90)
            }
            let reference = pixel(bitmap, 40, bitmap.pixelsHigh - 20)
            #expect(contains(reference, in: bitmap, above: bitmap.pixelsHigh / 2))
        }
    }

    @Test func exclusiveScaleKeepsConcurrentHoldersFromInterleaving() async {
        var log: [String] = []
        await withTaskGroup(of: Void.self) { group in
            for name in ["first", "second", "third"] {
                group.addTask { @MainActor in
                    await RenderCapture.exclusiveScale {
                        log.append(name + " in")
                        try? await Task.sleep(for: .milliseconds(30))
                        await RenderCapture.exclusiveScale { await Task.yield() }
                        log.append(name + " out")
                    }
                }
            }
        }
        #expect(log.count == 6)
        for index in stride(from: 0, to: log.count, by: 2) {
            #expect(log[index].dropLast(3) == log[index + 1].dropLast(4))
        }
    }

    @Test func controlsGalleryRendersEveryThemeInBothSchemes() async throws {
        for theme in AppTheme.allCases {
            try await withTheme(theme) {
                for dark in [false, true] {
                    try await rendered(
                        "controls-\(theme.rawValue)", dark: dark, width: 560, height: 300
                    ) {
                        Self.gallery
                    }
                }
            }
        }
    }

    private static var gallery: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ForEach([ControlSize.mini, .small, .regular, .large], id: \.self) { size in
                    Toggle("On", isOn: .constant(true)).labelsHidden()
                        .toggleStyle(.edithSwitch).controlSize(size)
                    Toggle("Off", isOn: .constant(false)).labelsHidden()
                        .toggleStyle(.edithSwitch).controlSize(size)
                }
            }
            HStack(spacing: 14) {
                ForEach([ControlSize.mini, .small, .regular, .large], id: \.self) { size in
                    Toggle("On", isOn: .constant(true)).labelsHidden()
                        .toggleStyle(.switch).controlSize(size)
                    Toggle("Off", isOn: .constant(false)).labelsHidden()
                        .toggleStyle(.switch).controlSize(size)
                }
            }
            Toggle("Labelled outside a form", isOn: .constant(true)).toggleStyle(.edithSwitch)
            Toggle("Disabled", isOn: .constant(true)).toggleStyle(.edithSwitch).disabled(true)
            HStack(spacing: 14) {
                Button("Primary") {}.buttonStyle(.edith(.primary))
                Toggle("Checked", isOn: .constant(true)).toggleStyle(.edithCheckbox)
                EdithLink("A themed link", destination: URL(string: "https://example.com")!)
                Button("Action link") {}.buttonStyle(.edithLink)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @Test func onAccentKeepsReadableContrastForEveryTheme() {
        for theme in AppTheme.allCases {
            for dark in [false, true] {
                let accent = theme.accentNSColor(dark: dark)
                let chosen = OnAccent.foreground(on: accent)
                #expect(
                    OnAccent.contrast(chosen, accent) >= 3,
                    "\(theme.rawValue) dark \(dark)")
                if OnAccent.luminance(accent) > OnAccent.whiteLuminanceLimit {
                    #expect(chosen == OnAccent.ink, "\(theme.rawValue) dark \(dark)")
                }
            }
        }
    }

    @Test func onAccentPicksInkOnLightThemesAndWhiteOnDeepThemes() {
        #expect(OnAccent.foreground(on: AppTheme.teal.accentNSColor(dark: false)) == OnAccent.ink)
        #expect(OnAccent.foreground(on: AppTheme.green.accentNSColor(dark: true)) == OnAccent.ink)
        #expect(OnAccent.foreground(on: AppTheme.orange.accentNSColor(dark: false)) == OnAccent.ink)
        #expect(OnAccent.foreground(on: AppTheme.indigo.accentNSColor(dark: false)) == .white)
        #expect(OnAccent.foreground(on: AppTheme.purple.accentNSColor(dark: true)) == .white)
        #expect(OnAccent.foreground(on: AppTheme.accent.accentNSColor(dark: false)) == .white)
        #expect(OnAccent.foreground(on: AppTheme.accent.accentNSColor(dark: true)) == OnAccent.ink)
    }

    @Test func primaryButtonInkFollowsTheAccentLuminance() async throws {
        for (theme, wanted) in [(AppTheme.teal, OnAccent.ink), (.indigo, NSColor.white)] {
            try await withTheme(theme) {
                let bitmap = try await rendered("primary-\(theme.rawValue)") {
                    Button("Primary action") {}.buttonStyle(.edith(.primary))
                        .font(.system(size: 24, weight: .bold)).padding(20)
                        .frame(width: 320, height: 90, alignment: .topLeading)
                    Rectangle().fill(Color(wanted)).frame(width: 320, height: 90)
                }
                let reference = pixel(bitmap, 40, bitmap.pixelsHigh - 20)
                #expect(contains(reference, in: bitmap, above: bitmap.pixelsHigh / 2))
            }
        }
    }

    @Test func selectionPaintsTheThemeInsteadOfTheSystemHighlight() async throws {
        try await withTheme(.teal) {
            let rows = [ThemedRow(id: 0), ThemedRow(id: 1), ThemedRow(id: 2)]
            let rendered = try await RenderCapture.render(
                "selection", variant: RenderCapture.variants[0]
            ) {
                Table(rows, selection: .constant(1)) {
                    TableColumn("Value") { row in Text("Row \(row.id)") }
                }.themedSelection()
            }
            let table = try #require(Self.table(in: rendered.host))
            #expect(table.selectionHighlightStyle == .none)
            let painted = table.subviews.filter { $0 is ThemedSelectionFill && !$0.isHidden }
            #expect(painted.count == 1)
            let frame = try #require(painted.first).frame
            #expect(frame.midY == table.rect(ofRow: 1).midY)
        }
    }

    @Test func sidebarListSelectionPaintsTheTheme() async throws {
        try await withTheme(.teal) {
            for dark in [false, true] {
                let rendered = try await rendered(
                    "selection-sidebar", dark: dark, width: 520, height: 240
                ) {
                    HStack(spacing: 0) {
                        List(selection: .constant("orders")) {
                            DisclosureGroup("Tables", isExpanded: .constant(true)) {
                                ForEach(["customers", "orders", "invoices"], id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .themedSelection()
                        Table([1, 2, 3].map(ThemedRow.init), selection: .constant(2)) {
                            TableColumn("Process") { row in Text("process \(row.id)") }
                        }
                        .themedSelection()
                    }
                }
                #expect(rendered.pixelsWide > 0)
            }
        }
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = table(in: child) { return table }
        }
        return nil
    }
}
