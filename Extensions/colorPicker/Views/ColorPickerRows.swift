import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct ColorPickerRows: View {
    let presentation: ControlPresentation
    @AppStorage(AppStorageKeys.ColorPicker.copyFormat, store: SharedDefaults.store) private
        var copyFormat: ColorCopyFormat = .hex
    @AppStorage(AppStorageKeys.ColorPicker.profile, store: SharedDefaults.store) private
        var profile: ColorProfile = .sRGB
    @AppStorage(AppStorageKeys.ColorPicker.historySize, store: SharedDefaults.store) private
        var historySize = 100
    @State private var history: [ColorSwatch] = ColorHistoryStore.load()

    @State private var historyObserver: NSObjectProtocol?

    private static let sample = ColorSwatch(
        red: 0.1, green: 0.45, blue: 0.91, profile: .sRGB)

    var body: some View {
        Group {
            if !presentation.active {
                Section {
                    DeskSettingsNotice(
                        title: "Color Picker is off",
                        message: "Turn it on to pick colors and change these settings.")
                }
            } else if presentation.ready, let error = presentation.error {
                Section {
                    DeskSettingsError(
                        title: "Color Picker is not responding", message: error,
                        retry: presentation.retry)
                }
            }
            Group {
                Section {
                    LabeledContent {
                        Button("Pick Color") { presentation.perform("pick") }
                            .buttonStyle(.edith(.primary))
                    } label: {
                        Text("Pick a color")
                        Text(
                            "Opens a magnifier over your screen. Click any pixel to copy its color.")
                    }
                    DeskShortcutRow(
                        keyPrefix: "colorPickerHotKey", defaultLabel: "\u{2303}\u{2325}\u{2318}C",
                        purpose: "Opens the magnifier from any app.")
                }
                Section("Copying") {
                    Picker(selection: $copyFormat.notifyingSettingsChange()) {
                        ForEach(ColorCopyFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    } label: {
                        Text("Copy as")
                        Text("A picked color pastes as \(Self.sample.string(for: copyFormat)).")
                    }
                    Picker(selection: $profile.notifyingSettingsChange()) {
                        ForEach(ColorProfile.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    } label: {
                        Text("Color space")
                        Text(
                            "sRGB matches the web. Display P3 keeps the extra colors of wide-color screens."
                        )
                    }
                    LabeledContent {
                        HStack(spacing: UIScale.pt(8)) {
                            Text("\(historySize)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: UIScale.pt(28), alignment: .trailing)
                            Stepper(
                                "Colors to remember", value: $historySize.notifyingSettingsChange(),
                                in: 1...100
                            )
                            .labelsHidden()
                        }
                    } label: {
                        Text("Colors to remember")
                        Text("Older colors are removed once the list is full.")
                    }
                }
            }
            .disabled(!presentation.active)
            .opacity(presentation.active ? 1 : 0.5)

            if presentation.active {
                Section {
                    if history.isEmpty {
                        LabeledContent {
                            EmptyView()
                        } label: {
                            Text("No colors yet")
                            Text(
                                "Colors you pick appear here, newest first. Click one to copy it again."
                            )
                        }
                    } else {
                        ColorSwatchGrid(history: history, defaultFormat: copyFormat)
                    }
                } header: {
                    Text("Recent colors")
                } footer: {
                    if !history.isEmpty {
                        Text(
                            "Click a swatch to copy it as \(copyFormat.displayName). Right-click for other formats."
                        )
                        .font(.edithText(.subheadline))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            history = ColorHistoryStore.load()
            historyObserver = IPC.observe(IPC.Name.settingsChanged) {
                history = ColorHistoryStore.load()
            }
        }
        .onDisappear {
            if let historyObserver { IPC.stopObserving(historyObserver) }
            historyObserver = nil
        }
    }
}

private struct ColorSwatchGrid: View {
    let history: [ColorSwatch]
    let defaultFormat: ColorCopyFormat

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: UIScale.pt(28)), spacing: UIScale.pt(8))],
            alignment: .leading, spacing: UIScale.pt(8)
        ) {
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
            RoundedRectangle(cornerRadius: UIScale.pt(6))
                .fill(swatch.color)
                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(6)).strokeBorder(
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
            "Could not copy color",
            isPresented: Binding(
                get: { copyError != nil },
                set: { if !$0 { copyError = nil } })
        ) {
            Button("OK") { copyError = nil }
        } message: {
            Text(copyError ?? "The clipboard did not accept the color. Try again.")
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
