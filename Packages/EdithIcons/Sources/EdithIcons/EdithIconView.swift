import SwiftUI

public enum EdithIconLayer: Sendable {
    case primary
    case secondary
}

public enum EdithIconCut: CGFloat, CaseIterable, Sendable {
    case small = 16
    case regular = 20

    public var grid: CGFloat { rawValue }

    public static func optical(for size: CGFloat) -> EdithIconCut {
        size < 18 || size == 24 || size == 32 ? .small : .regular
    }
}

public enum EdithIconTone: Sendable {
    case duotone
    case monochrome

    public static let secondaryOpacity = 0.45

    var secondaryOpacity: Double {
        switch self {
        case .duotone: Self.secondaryOpacity
        case .monochrome: 1
        }
    }
}

public struct EdithIconShape: Shape {
    public let icon: EdithIcon
    public let layer: EdithIconLayer
    public let cut: EdithIconCut

    public init(_ icon: EdithIcon, layer: EdithIconLayer = .primary, cut: EdithIconCut = .regular) {
        self.icon = icon
        self.layer = layer
        self.cut = cut
    }

    public func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / cut.grid
        return EdithIconPathParser.path(from: icon.pathData(layer, cut: cut))
            .applying(
                CGAffineTransform(scaleX: scale, y: scale)
                    .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

public struct EdithIconView: View {
    private let icon: EdithIcon
    private let size: CGFloat
    private let cut: EdithIconCut
    private let tone: EdithIconTone

    public init(
        _ icon: EdithIcon, size: CGFloat = 20, cut: EdithIconCut? = nil,
        tone: EdithIconTone = .duotone
    ) {
        self.icon = icon
        self.size = size
        self.cut = cut ?? .optical(for: size)
        self.tone = tone
    }

    public var body: some View {
        ZStack {
            EdithIconShape(icon, layer: .secondary, cut: cut)
                .fill(style: FillStyle(eoFill: true))
                .opacity(tone.secondaryOpacity)
            EdithIconShape(icon, layer: .primary, cut: cut)
                .fill(style: FillStyle(eoFill: true))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
