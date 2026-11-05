@_exported import EdithIcons
import SwiftUI

public struct PageIcon: View {
    private let icon: EdithIcon
    private let size: CGFloat
    private let tone: EdithIconTone

    public init(icon: EdithIcon, size: CGFloat, tone: EdithIconTone = .duotone) {
        self.icon = icon
        self.size = size
        self.tone = tone
    }

    public init(
        extensionID: String?, icon: EdithIcon, size: CGFloat, tone: EdithIconTone = .duotone
    ) {
        self.icon = extensionID.flatMap(EdithIcon.init(rawValue:)) ?? icon
        self.size = size
        self.tone = tone
    }

    public static func side(_ size: CGFloat) -> CGFloat { UIScale.pt(size).rounded() }

    var leadingInset: CGFloat {
        let side = Self.side(size)
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let cut = EdithIconCut.optical(for: side)
        let ink = [EdithIconLayer.primary, .secondary]
            .map { EdithIconShape(icon, layer: $0, cut: cut).path(in: rect) }
            .filter { !$0.isEmpty }
            .map(\.boundingRect)
            .reduce(CGRect.null) { $0.union($1) }
        return ink.isNull ? 0 : ink.minX.rounded()
    }

    public var body: some View {
        EdithIconView(icon, size: Self.side(size), tone: tone)
    }
}
