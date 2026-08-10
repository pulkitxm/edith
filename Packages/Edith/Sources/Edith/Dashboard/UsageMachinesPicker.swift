import EdithKit
import SwiftUI

struct UsageMachinesPicker: View {
    @ObservedObject var model: DashboardModel
    let dark: Bool
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Text("Machines")
                .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.horizontal, UIScale.pt(6))
            Text("Tick a machine to count it in the charts. Option-click to show it alone.")
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, UIScale.pt(6))
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(1)) {
                    ForEach(model.machineGroups) { group in
                        shownRow(group)
                    }
                }
            }
            .frame(maxHeight: UIScale.pt(520))
            Divider().opacity(0.4)
            HStack(spacing: UIScale.pt(10)) {
                Text(footnote)
                    .font(DashSkin.mono(10))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .buttonStyle(.plain).pointerCursor()
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
            }
            .padding(.horizontal, UIScale.pt(6))
        }
        .padding(UIScale.pt(12))
        .frame(width: UIScale.pt(400))
    }

    private var footnote: String {
        let shown = model.machineGroups.filter { model.machineIsShown($0) }.count
        return shown == 1 ? "1 machine shown" : "\(shown) machines shown"
    }

    private func shownRow(_ group: MachineGroup) -> some View {
        let shown = model.machineIsShown(group)
        let partial = model.machineIsPartlyShown(group)
        let mark = shown ? "checkmark.circle.fill" : (partial ? "circle.lefthalf.filled" : "circle")
        return Button {
            if NSEvent.modifierFlags.contains(.option) {
                model.showOnlyMachine(group)
            } else {
                model.showMachine(group, !shown)
            }
        } label: {
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: mark)
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(
                        shown || partial ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(group.name)
                        .font(
                            .system(size: UIScale.pt(11.5), weight: shown ? .semibold : .regular)
                        )
                        .foregroundStyle(DashSkin.ink(dark))
                    Text(group.agentSummary)
                        .font(DashSkin.mono(9.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: UIScale.pt(8))
                Text(agentCount(group))
                    .font(DashSkin.mono(9.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .padding(.horizontal, UIScale.pt(9))
            .padding(.vertical, UIScale.pt(7))
            .contentShape(Rectangle())
        }
        .buttonStyle(MachineRowStyle(dark: dark))
        .pointerCursor()
        .padding(.horizontal, UIScale.pt(2))
    }

    private func agentCount(_ group: MachineGroup) -> String {
        group.sourceIDs.count == 1 ? "1 agent" : "\(group.sourceIDs.count) agents"
    }

}

private struct MachineRowStyle: ButtonStyle {
    let dark: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                hovering ? DashSkin.inkFaint(dark).opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(6))
            )
            .onHover { hovering = $0 }
    }
}
