@_exported import EdithIcons
import SwiftUI

public struct PageIcon: View {
    private enum Glyph {
        case icon(EdithIcon)
        case symbol(String)
    }

    static let symbolScale = 0.62

    private let glyph: Glyph
    private let size: CGFloat
    private let tone: EdithIconTone

    public init(_ icon: EdithIcon, size: CGFloat, tone: EdithIconTone = .duotone) {
        self.glyph = .icon(icon)
        self.size = size
        self.tone = tone
    }

    public init(symbolName: String, size: CGFloat) {
        self.glyph = .symbol(symbolName)
        self.size = size
        self.tone = .duotone
    }

    public init(
        extensionID: String?, symbolName: String, size: CGFloat, tone: EdithIconTone = .duotone
    ) {
        self.glyph =
            extensionID.flatMap(EdithIcon.init(rawValue:)).map(Glyph.icon)
            ?? .symbol(symbolName)
        self.size = size
        self.tone = tone
    }

    public static func side(_ size: CGFloat) -> CGFloat { UIScale.pt(size).rounded() }

    var leadingInset: CGFloat {
        guard case .icon(let icon) = glyph else { return 0 }
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
        let side = Self.side(size)
        switch glyph {
        case .icon(let icon):
            EdithIconView(icon, size: side, tone: tone)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: side * Self.symbolScale, weight: .medium))
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        }
    }
}
