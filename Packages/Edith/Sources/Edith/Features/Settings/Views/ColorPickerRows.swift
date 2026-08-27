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

    var body: some View {
        Group {
            Section {
                Button("Pick now") {
                    _ = ColorPickerOperationExecution.request(.pick)
                }
                LabeledContent {
                    HotKeyRecorderControl(keyPrefix: "colorPickerHotKey", defaultLabel: "⌃⌥⌘C")
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Pick hotkey")
                        InfoDot("Summons the magnifier from anywhere.")
                    }
                }
                Picker(
                    "Copy format",
                    selection: $copyFormat.configured(AppStorageKeys.ColorPicker.copyFormat)
                ) {
                    ForEach(ColorCopyFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                Picker(selection: $profile.configured(AppStorageKeys.ColorPicker.profile)) {
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
                Stepper(
                    value: $historySize.configured(AppStorageKeys.ColorPicker.historySize),
                    in: 1...100
                ) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("History size: \(historySize)")
                        InfoDot("How many past colors to keep.")
                    }
                }
            }
            .disabled(!colorPickerEnabled)
            .opacity(colorPickerEnabled ? 1 : 0.5)

            if colorPickerEnabled, !history.isEmpty {
                Section {
                    ColorSwatchGrid(history: history, defaultFormat: copyFormat)
                } header: {
                    Text("Recent Colors")
                }
            }
        }
        .onAppear { history = ColorHistoryStore.load() }
    }
}
private struct ColorSwatchGrid: View {
    let history: [ColorSwatch]
    let defaultFormat: ColorCopyFormat

    private let columns = [GridItem(.adaptive(minimum: 28), spacing: UIScale.pt(6))]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: UIScale.pt(6)) {
            ForEach(history) { swatch in
                ColorSwatchChip(swatch: swatch, defaultFormat: defaultFormat)
            }
        }
    }
}

private struct ColorSwatchChip: View {
    let swatch: ColorSwatch
    let defaultFormat: ColorCopyFormat
    @State private var copyError: String?

    var body: some View {
        Button {
            copy(defaultFormat)
        } label: {
            RoundedRectangle(cornerRadius: UIScale.pt(5))
                .fill(swatch.color)
                .frame(width: UIScale.pt(26), height: UIScale.pt(26))
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(5)).strokeBorder(
                        .primary.opacity(0.12))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.iconOnly))
        .accessibilityLabel("Copy \(swatch.string(for: defaultFormat))")
        .contextMenu {
            ForEach(ColorCopyFormat.allCases, id: \.self) { format in
                Button(swatch.string(for: format)) { copy(format) }
            }
        }
        .help(swatch.string(for: defaultFormat))
        .alert(
            "Could not copy colour",
            isPresented: Binding(
                get: { copyError != nil },
                set: { if !$0 { copyError = nil } })
        ) {
            Button("OK") { copyError = nil }
        } message: {
            Text(copyError ?? "The pasteboard refused the colour value.")
        }
    }

    private func copy(_ format: ColorCopyFormat) {
        do {
            try ColorSwatchOperationExecution.perform(
                .copy, swatch: swatch, format: format,
                write: { value in
                    NSPasteboard.general.clearContents()
                    return NSPasteboard.general.setString(value, forType: .string)
                })
            copyError = nil
        } catch {
            copyError = error.localizedDescription
        }
    }
}
