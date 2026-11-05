import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct DeskSettingsNotice: View {
    let title: String
    let message: String

    var body: some View {
        LabeledContent {
            EmptyView()
        } label: {
            Text("\(Image(systemName: "power.circle.fill")) \(title)")
            Text(message)
        }
    }
}

struct DeskSettingsError: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        LabeledContent {
            Button("Try Again", action: retry).buttonStyle(.edith(.secondary))
        } label: {
            Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundColor(.orange)
                + Text(" " + title)
            Text(message)
        }
    }
}

struct DeskShortcutRow: View {
    let keyPrefix: String
    let defaultLabel: String
    let purpose: String

    var body: some View {
        LabeledContent {
            HotKeyRecorderControl(keyPrefix: keyPrefix, defaultLabel: defaultLabel)
        } label: {
            Text("Keyboard shortcut")
            Text(purpose + " Click the shortcut, then press new keys to change it.")
        }
    }
}

struct DeskSliderRow: View {
    let title: String
    let detail: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let readout: String

    var body: some View {
        LabeledContent {
            HStack(spacing: UIScale.pt(12)) {
                slider
                    .labelsHidden()
                    .frame(width: UIScale.pt(180))
                Text(readout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: UIScale.pt(56), alignment: .trailing)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    @ViewBuilder private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step) { Text(title) }
        } else {
            Slider(value: $value, in: range) { Text(title) }
        }
    }
}

extension View {
    func deskForm() -> some View {
        edithForm().controlSize(UIScale.controlSize)
    }
}
