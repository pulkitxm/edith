import EdithKit
import SwiftUI

struct TerminalDropTransferStatus: View {
    let holder: TerminalSessionHolder
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            if holder.transferringDrop {
                SkeletonGroup {
                    HStack(spacing: UIScale.pt(6)) {
                        SkeletonBlock(width: 12, height: 12, corner: 3)
                        SkeletonBlock(width: 74, height: 9)
                    }
                    .padding(.horizontal, UIScale.pt(9))
                    .padding(.vertical, UIScale.pt(7))
                    .background(
                        DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                }
                .accessibilityLabel("Transferring files")
                .padding(UIScale.pt(10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if let error = holder.dropTransferError {
                Text(error)
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                    .foregroundStyle(DashSkin.warn)
                    .padding(UIScale.pt(10))
                    .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 8))
                    .padding(UIScale.pt(10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
    }
}
