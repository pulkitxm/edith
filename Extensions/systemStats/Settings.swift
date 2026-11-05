import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct SystemStatsColorPreference {
    let mode: MenuBarTintMode
    let hex: String?

    init(defaults: UserDefaults) {
        mode = MenuBarTintMode(
            preference: defaults.string(forKey: AppStorageKeys.MenuBar.statsColorMode))
        hex = defaults.string(forKey: AppStorageKeys.MenuBar.statsColorHex)
    }

    var cacheKey: String { "\(mode):\(hex ?? "")" }
    var tint: NSColor { mode.color(custom: customColor) }

    var customColor: NSColor? {
        guard var value = hex else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((number >> 16) & 0xff) / 255,
            green: CGFloat((number >> 8) & 0xff) / 255,
            blue: CGFloat(number & 0xff) / 255, alpha: 1)
    }
}

struct SystemStatsRows: View {
    let presentation: ControlPresentation
    private let defaults: UserDefaults
    @AppStorage private var statsColorHex: String
    @AppStorage private var statsColorMode: String

    init(presentation: ControlPresentation, defaults: UserDefaults = SharedDefaults.store) {
        self.presentation = presentation
        self.defaults = defaults
        _statsColorHex = AppStorage(
            wrappedValue: "FFFFFF", AppStorageKeys.MenuBar.statsColorHex, store: defaults)
        _statsColorMode = AppStorage(
            wrappedValue: "auto", AppStorageKeys.MenuBar.statsColorMode, store: defaults)
    }

    var modeBinding: Binding<String> {
        Binding(
            get: { statsColorMode == "custom" ? "custom" : "auto" },
            set: { presentation.setPreference($0, for: AppStorageKeys.MenuBar.statsColorMode) })
    }

    var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: SystemStatsColorPreference(defaults: defaults).customColor ?? .white)
            },
            set: { presentation.setPreference($0.hex6, for: AppStorageKeys.MenuBar.statsColorHex) })
    }

    private var running: Bool { presentation.active && presentation.running }

    var body: some View {
        Section {
            Picker(selection: modeBinding) {
                Text("Automatic").tag("auto")
                Text("Custom").tag("custom")
            } label: {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("Color")
                    Text("Automatic matches the other items in your menu bar.")
                        .settingsCaption()
                }
            }
            .disabled(!running)
            if statsColorMode == "custom" {
                ColorPicker("Custom color", selection: colorBinding, supportsOpacity: false)
                    .disabled(!running)
            }
        } header: {
            Text("Menu bar appearance")
        } footer: {
            Text(
                running
                    ? "CPU and memory update every couple of seconds and pause while your Mac sleeps or is locked."
                    : "Menu Bar Stats is turned off. Turn it on in Extensions to change these."
            )
            .settingsCaption()
        }
    }
}

@MainActor
enum SystemStatsSettingsScene {
    static func accepts(_ input: NSDictionary) -> Bool {
        input["location"] as? String == "settings" && input["section"] as? String == "extension"
    }

    static func controller(
        presentation: ControlPresentation, defaults: UserDefaults = SharedDefaults.store
    ) -> NSViewController {
        NSHostingController(
            rootView: ExtensionPageHost {
                ControlSettingsHost(presentation: presentation) {
                    Form {
                        ControlSettingsIssueSection()
                        SystemStatsRows(presentation: presentation, defaults: defaults)
                    }
                    .edithForm()
                }
            })
    }
}

struct SystemStatsPage: View {
    let presentation: ControlPresentation
    let defaults: UserDefaults

    var body: some View {
        PageWorkspace {
            PageHeader(
                SystemStatsService.title,
                subtitle: "Live CPU and memory use, shown in your menu bar.", divider: true)
        } content: {
            ControlSettingsHost(presentation: presentation) {
                Form {
                    ControlSettingsIssueSection()
                    Section {
                        if presentation.active && presentation.running {
                            SystemStatsReadingRow(title: "CPU", percent: presentation.state.cpu)
                            SystemStatsReadingRow(
                                title: "Memory", percent: presentation.state.memory)
                        } else {
                            Text(
                                "Turn on \(SystemStatsService.title) in Extensions to see live readings."
                            )
                            .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Right now")
                    }
                    SystemStatsRows(presentation: presentation, defaults: defaults)
                }
                .edithForm()
                .frame(maxWidth: UIScale.pt(760), alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

struct SystemStatsReadingRow: View {
    let title: String
    let percent: Double

    private var clamped: Int { Int(max(0, min(100, percent)).rounded()) }

    var body: some View {
        HStack(spacing: UIScale.pt(12)) {
            Text(title)
                .frame(width: UIScale.pt(72), alignment: .leading)
            LoadingProgress(value: Double(clamped), total: 100)
                .accessibilityHidden(true)
            Text("\(clamped)%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: UIScale.pt(40), alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(clamped) percent used")
    }
}
