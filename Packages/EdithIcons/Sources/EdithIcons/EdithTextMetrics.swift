import SwiftUI

public enum EdithIconText {
    private static let pixelExactSizes: [CGFloat] = [12, 16, 20, 24, 32, 40]
    private static let largestSnappedLine: CGFloat = 50
    static let lineHeightToPointSize: CGFloat = 1.23

    public static func iconSize(forLineHeight line: CGFloat, scale: Image.Scale = .medium)
        -> CGFloat
    {
        let target = line * factor(for: scale)
        guard target < largestSnappedLine else { return target.rounded() }
        return pixelExactSizes.min { abs($0 - target) < abs($1 - target) } ?? target.rounded()
    }

    static func factor(for scale: Image.Scale) -> CGFloat {
        switch scale {
        case .small: 0.82
        case .large: 1.25
        default: 1
        }
    }
}

struct EdithTextSizedIcon: View {
    let icon: EdithIcon
    let cut: EdithIconCut?
    let tone: EdithIconTone
    @Environment(\.imageScale) private var imageScale

    var body: some View {
        EdithTextLineLayout(scale: imageScale) {
            Text(verbatim: "Hg").lineLimit(1).fixedSize().hidden()
            EdithIconGraphic(icon: icon, cut: cut, tone: tone)
        }
    }
}

struct EdithTextLineLayout: Layout {
    let scale: Image.Scale

    private func side(_ line: CGSize) -> CGFloat {
        EdithIconText.iconSize(forLineHeight: line.height, scale: scale)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let line = text.sizeThatFits(.unspecified)
        let side = side(line)
        return CGSize(width: side, height: max(side, line.height))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let line = subviews[0].sizeThatFits(.unspecified)
        let side = side(line)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(line))
        subviews[1].place(
            at: CGPoint(
                x: bounds.minX + ((bounds.width - side) / 2).rounded(),
                y: bounds.minY + ((bounds.height - side) / 2).rounded()),
            anchor: .topLeading, proposal: ProposedViewSize(width: side, height: side))
    }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline,
            let text = subviews.first
        else { return nil }
        let line = text.sizeThatFits(.unspecified)
        let dimensions = text.dimensions(in: ProposedViewSize(line))
        return bounds.midY - line.height / 2 + dimensions[guide]
    }
}
