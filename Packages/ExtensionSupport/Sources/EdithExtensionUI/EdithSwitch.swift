import EdithExtensionCore
import SwiftUI

struct EdithSwitchMetrics: Equatable, Sendable {
    let width: Double
    let height: Double

    let inset = 2.0
    var knobHeight: Double { height - inset * 2 }
    var knobWidth: Double { (knobHeight * 1.6).rounded() }

    static func metrics(for size: ControlSize) -> Self {
        switch size {
        case .mini: Self(width: 36, height: 16)
        case .small: Self(width: 44, height: 20)
        case .large: Self(width: 64, height: 28)
        case .extraLarge: Self(width: 80, height: 36)
        default: Self(width: 54, height: 24)
        }
    }
}

public struct EdithSwitchStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        EdithSwitchBody(configuration: configuration)
    }
}

extension ToggleStyle where Self == EdithSwitchStyle {
    public static var edithSwitch: EdithSwitchStyle { EdithSwitchStyle() }
}

private struct EdithSwitchBody: View {
    let configuration: ToggleStyleConfiguration

    var body: some View {
        LabeledContent {
            control
        } label: {
            configuration.label.accessibilityHidden(true)
        }
    }

    private var control: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            EdithSwitchTrack(isOn: configuration.isOn)
                .background {
                    configuration.label.foregroundStyle(.clear).frame(width: 1, height: 1).clipped()
                }
        }
        .buttonStyle(.edithControl)
        .focusEffectDisabled()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

private struct EdithSwitchTrack: View {
    let isOn: Bool
    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.process.defaults())
    private var themeName = "accent"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    private var metrics: EdithSwitchMetrics { .metrics(for: controlSize) }

    var body: some View {
        let accent = themeColor(themeName)
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? accent : Color.primary.opacity(offFill))
            Capsule()
                .fill(.white)
                .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                .frame(width: metrics.knobWidth, height: metrics.knobHeight)
                .padding(metrics.inset)
        }
        .frame(width: metrics.width, height: metrics.height)
        .overlay {
            if focused, enabled {
                Capsule().strokeBorder(accent, lineWidth: 2).padding(-3)
            } else if contrast == .increased {
                Capsule().strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
            }
        }
        .contentShape(Capsule())
        .opacity(enabled ? 1 : 0.42)
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: isOn)
    }

    private var offFill: Double { contrast == .increased ? 0.24 : 0.12 }
}
