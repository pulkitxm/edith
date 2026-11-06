import EdithExtensionUI
import SwiftUI

struct UsageRowButtonStyle: ButtonStyle {
    var fillsTarget = false

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if fillsTarget {
                configuration.label.edithButtonTarget(.row)
            } else {
                configuration.label
            }
        }
        .edithHoverHighlight(
            tone: .neutral, cornerRadius: UIScale.pt(6), pressed: configuration.isPressed)
    }
}
