import SwiftUI

public enum EdithIconLayer: Hashable, Sendable {
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

public enum EdithIconTone: Hashable, Sendable {
    case duotone
    case monochrome
    case muted

    public static let secondaryOpacity = 0.45

    var primaryOpacity: Double {
        self == .muted ? Self.secondaryOpacity : 1
    }

    var secondaryOpacity: Double {
        self == .monochrome ? 1 : Self.secondaryOpacity
    }
}

public struct EdithIconShape: Shape {
    public let icon: EdithIcon
    public let layer: EdithIconLayer
    public let cut: EdithIconCut?

    public init(_ icon: EdithIcon, layer: EdithIconLayer = .primary, cut: EdithIconCut? = nil) {
        self.icon = icon
        self.layer = layer
        self.cut = cut
    }

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let cut = cut ?? .optical(for: side)
        let scale = side / cut.grid
        return EdithIconPathStore.path(icon, layer: layer, cut: cut)
            .applying(
                CGAffineTransform(scaleX: scale, y: scale)
                    .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

public struct EdithIconView: View {
    private let icon: EdithIcon
    private let size: CGFloat?
    private let cut: EdithIconCut?
    private let tone: EdithIconTone

    public init(
        _ icon: EdithIcon, size: CGFloat? = nil, cut: EdithIconCut? = nil,
        tone: EdithIconTone = .duotone
    ) {
        self.icon = icon
        self.size = size
        self.cut = cut
        self.tone = tone
    }

    public var body: some View {
        if let size {
            EdithIconGraphic(icon: icon, cut: cut ?? .optical(for: size), tone: tone)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            EdithTextSizedIcon(icon: icon, cut: cut, tone: tone)
                .accessibilityHidden(true)
        }
    }
}

struct EdithIconGraphic: View {
    let icon: EdithIcon
    let cut: EdithIconCut?
    let tone: EdithIconTone

    var body: some View {
        ZStack {
            if icon.hasSecondaryPlate {
                EdithIconShape(icon, layer: .secondary, cut: cut)
                    .fill(style: FillStyle(eoFill: true))
                    .opacity(tone.secondaryOpacity)
            }
            EdithIconShape(icon, layer: .primary, cut: cut)
                .fill(style: FillStyle(eoFill: true))
                .opacity(tone.primaryOpacity)
        }
    }
}

extension EdithIcon {
    var hasSecondaryPlate: Bool {
        !pathData(.secondary, cut: .regular).isEmpty
    }
}
