import EdithKit
import SwiftUI

struct MachineCoolingCard: View {
    let session: MachineSession
    let dark: Bool

    private var fans: [MachineFan] { session.slow?.fans ?? [] }

    var body: some View {
        SkinCard(title: "Cooling", note: "Live fan speeds", dark: dark) {
            VStack(spacing: UIScale.pt(8)) {
                ForEach(fans) { fan in
                    HStack {
                        Label(fan.label, systemImage: "fan")
                            .font(.system(size: UIScale.pt(12), weight: .medium))
                            .foregroundStyle(DashSkin.ink(dark))
                        Spacer()
                        Text("\(fan.rpm.formatted()) rpm")
                            .font(DashSkin.mono(11))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
            }
        }
    }
}
