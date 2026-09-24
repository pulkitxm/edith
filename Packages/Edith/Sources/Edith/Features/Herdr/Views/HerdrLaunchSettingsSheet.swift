import EdithKit
import SwiftUI

struct HerdrLaunchSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var commands: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(HerdrKind.filterLabels, id: \.self) { kind in
                        row(for: kind)
                        if kind != HerdrKind.filterLabels.last { Divider() }
                    }
                }
            }
        }
        .frame(width: UIScale.pt(440), height: UIScale.pt(420))
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text("Agent Launch Commands")
                    .font(.system(size: UIScale.pt(16), weight: .semibold))
                Text("The command typed into a new pane when you launch this kind of agent.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.edith(.borderless))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(UIScale.pt(18))
    }

    private func row(for kind: String) -> some View {
        let isDefault = HerdrLaunchSettings.usesHerdrAgentStart(for: kind)
        return HStack(spacing: UIScale.pt(10)) {
            HerdrKindMark(kind: kind, size: UIScale.pt(16))
            Text(kind)
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .frame(width: UIScale.pt(96), alignment: .leading)
            TextField(
                "Command",
                text: Binding(
                    get: { commands[kind] ?? "" },
                    set: { newValue in
                        commands[kind] = newValue
                        HerdrLaunchSettings.setCommand(newValue, for: kind)
                    })
            )
            .textFieldStyle(.roundedBorder)
            Button("Reset") {
                HerdrLaunchSettings.resetToDefault(for: kind)
                commands[kind] = HerdrLaunchSettings.command(for: kind)
            }
            .buttonStyle(.edith(.borderless))
            .font(.system(size: UIScale.pt(11)))
            .disabled(isDefault)
        }
        .padding(.horizontal, UIScale.pt(18))
        .padding(.vertical, UIScale.pt(10))
    }

    private func reload() {
        commands = Dictionary(
            uniqueKeysWithValues: HerdrKind.filterLabels.map {
                ($0, HerdrLaunchSettings.command(for: $0))
            }
        )
    }
}
