import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct ColorPickerRows: View {
    @AppStorage(AppStorageKeys.ColorPicker.enabled, store: SharedDefaults.store) private
        var colorPickerEnabled =
        false
    @AppStorage(AppStorageKeys.ColorPicker.copyFormat, store: SharedDefaults.store) private
        var copyFormat: ColorCopyFormat = .hex
    @AppStorage(AppStorageKeys.ColorPicker.profile, store: SharedDefaults.store) private
        var profile: ColorProfile = .sRGB
    @AppStorage(AppStorageKeys.ColorPicker.historySize, store: SharedDefaults.store) private
        var historySize = 100
    @State private var history: [ColorSwatch] = ColorHistoryStore.load()
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            SkinCard(title: "Color Picker", dark: dark) {
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    LabeledContent {
                        HotKeyRecorderControl(keyPrefix: "colorPickerHotKey", defaultLabel: "⌃⌥⌘C")
                    } label: {
                        HStack(spacing: UIScale.pt(6)) {
                            Text("Pick hotkey")
                            InfoDot("Summons the magnifier from anywhere.")
                        }
                    }
                    Picker("Copy format", selection: $copyFormat) {
                        ForEach(ColorCopyFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pointerCursor()
                    Picker(selection: $profile) {
                        ForEach(ColorProfile.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    } label: {
                        HStack(spacing: UIScale.pt(6)) {
                            Text("Color profile")
                            InfoDot(
                                "Compute values in sRGB or Display P3 - they differ on wide-gamut screens like this MacBook's."
                            )
                        }
                    }
                    .pointerCursor()
                    Stepper(value: $historySize, in: 1...100) {
                        HStack(spacing: UIScale.pt(6)) {
                            Text("History size: \(historySize)")
                            InfoDot("How many past colors to keep.")
                        }
                    }
                    .pointerCursor()
                }
                .foregroundStyle(DashSkin.ink(dark))
                .disabled(!colorPickerEnabled)
                .opacity(colorPickerEnabled ? 1 : 0.5)
            }

            if colorPickerEnabled, !history.isEmpty {
                SkinCard(title: "Recent Colors", dark: dark) {
                    ColorSwatchGrid(history: history, defaultFormat: copyFormat, dark: dark)
                }
            }
        }
        .onAppear { history = ColorHistoryStore.load() }
    }
}
private struct ColorSwatchGrid: View {
    let history: [ColorSwatch]
    let defaultFormat: ColorCopyFormat
    let dark: Bool

    private let columns = [GridItem(.adaptive(minimum: 28), spacing: UIScale.pt(6))]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: UIScale.pt(6)) {
            ForEach(history) { swatch in
                ColorSwatchChip(swatch: swatch, defaultFormat: defaultFormat, dark: dark)
            }
        }
    }
}

private struct ColorSwatchChip: View {
    let swatch: ColorSwatch
    let defaultFormat: ColorCopyFormat
    let dark: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: UIScale.pt(5))
            .fill(swatch.color)
            .frame(width: UIScale.pt(26), height: UIScale.pt(26))
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(5)).strokeBorder(DashSkin.line(dark))
            )
            .contentShape(Rectangle())
            .onTapGesture { copy(defaultFormat) }
            .contextMenu {
                ForEach(ColorCopyFormat.allCases, id: \.self) { format in
                    Button(swatch.string(for: format)) { copy(format) }
                }
            }
            .help(swatch.string(for: defaultFormat))
            .pointerCursor()
    }

    private func copy(_ format: ColorCopyFormat) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(swatch.string(for: format), forType: .string)
    }
}
