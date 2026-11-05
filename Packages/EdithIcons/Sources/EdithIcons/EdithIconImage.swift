import AppKit
import SwiftUI

extension EdithIcon {
    private final class ImageKey: NSObject {
        let icon: EdithIcon
        let size: CGFloat
        let tone: EdithIconTone

        init(icon: EdithIcon, size: CGFloat, tone: EdithIconTone) {
            self.icon = icon
            self.size = size
            self.tone = tone
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(icon)
            hasher.combine(size)
            hasher.combine(tone)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? ImageKey else { return false }
            return icon == other.icon && size == other.size && tone == other.tone
        }
    }

    nonisolated(unsafe) private static let images = NSCache<ImageKey, NSImage>()
    private static let imageScales: [CGFloat] = [1, 2]

    public func nsImage(size: CGFloat = 16, tone: EdithIconTone = .duotone) -> NSImage {
        let key = ImageKey(icon: self, size: size, tone: tone)
        if let image = Self.images.object(forKey: key) { return image }
        let image = NSImage(size: NSSize(width: size, height: size))
        for scale in Self.imageScales {
            if let bitmap = renderBitmap(size: size, scale: scale, tone: tone) {
                image.addRepresentation(bitmap)
            }
        }
        image.isTemplate = true
        Self.images.setObject(image, forKey: key)
        return image
    }

    public func image(size: CGFloat = 16, tone: EdithIconTone = .duotone) -> Image {
        Image(nsImage: nsImage(size: size, tone: tone)).renderingMode(.template)
    }

    public func image(size: CGFloat = 16, tone: EdithIconTone = .duotone, tint: Color) -> Image {
        let mask = nsImage(size: size, tone: tone)
        let color = NSColor(tint)
        let tinted = NSImage(size: mask.size, flipped: false) { rect in
            mask.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        return Image(nsImage: tinted)
    }

    private func renderBitmap(size: CGFloat, scale: CGFloat, tone: EdithIconTone)
        -> NSBitmapImageRep?
    {
        let pixels = Int((size * scale).rounded(.up))
        guard
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: 0, y: -size)
        let plates: [(EdithIconLayer, Double)] = [
            (.secondary, tone.secondaryOpacity), (.primary, tone.primaryOpacity),
        ]
        for (layer, opacity) in plates {
            let path = EdithIconShape(self, layer: layer).path(in: rect)
            guard !path.isEmpty else { continue }
            context.setFillColor(CGColor(gray: 0, alpha: opacity))
            context.addPath(path.cgPath)
            context.fillPath(using: .evenOdd)
        }
        guard let cgImage = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        bitmap.size = NSSize(width: size, height: size)
        return bitmap
    }
}

public struct EdithLabelIcon: View {
    private let icon: EdithIcon
    private let tone: EdithIconTone
    @State private var lineHeight: CGFloat?
    @Environment(\.imageScale) private var imageScale

    public nonisolated init(_ icon: EdithIcon, tone: EdithIconTone = .duotone) {
        self.icon = icon
        self.tone = tone
    }

    private var size: CGFloat {
        EdithIconText.iconSize(forLineHeight: lineHeight ?? 16, scale: imageScale)
    }

    public var body: some View {
        icon.image(size: size, tone: tone)
            .background {
                Text(verbatim: "Hg").lineLimit(1).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { lineHeight = $0 }
            }
            .accessibilityHidden(true)
    }
}

extension Label where Title == Text, Icon == EdithLabelIcon {
    public init(_ title: LocalizedStringKey, edith icon: EdithIcon, tone: EdithIconTone = .duotone)
    {
        self.init {
            Text(title)
        } icon: {
            EdithLabelIcon(icon, tone: tone)
        }
    }

    public init<S: StringProtocol>(
        _ title: S, edith icon: EdithIcon, tone: EdithIconTone = .duotone
    ) {
        self.init {
            Text(title)
        } icon: {
            EdithLabelIcon(icon, tone: tone)
        }
    }
}

extension Button where Label == SwiftUI.Label<Text, EdithLabelIcon> {
    public init(
        _ title: LocalizedStringKey, edith icon: EdithIcon, role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.init(role: role, action: action) { SwiftUI.Label(title, edith: icon) }
    }

    public init<S: StringProtocol>(
        _ title: S, edith icon: EdithIcon, role: ButtonRole? = nil, action: @escaping () -> Void
    ) {
        self.init(role: role, action: action) { SwiftUI.Label(title, edith: icon) }
    }
}

extension Text {
    public init(edith icon: EdithIcon, size: CGFloat = 16, tone: EdithIconTone = .duotone) {
        self = Text(icon.image(size: size, tone: tone)).baselineOffset(-size * 0.2)
    }
}
