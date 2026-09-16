import AppKit
import EdithKit

struct SweaterPreviewSwatch {
    let app: String
    let image: NSImage

    static let all: [SweaterPreviewSwatch] = ["Edith", "Claude", "Finder", "Spotify"]
        .compactMap { app in
            guard let image = render(app: app) else { return nil }
            return SweaterPreviewSwatch(app: app, image: image)
        }

    private static func render(app: String) -> NSImage? {
        let scale = 3
        let size = CGSize(width: 84, height: 50)
        let width = Int(size.width) * scale
        let height = Int(size.height) * scale
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGImageByteOrderInfo.order32Host.rawValue)
        else { return nil }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        let window = CGRect(x: 13, y: 11, width: 58, height: 28)
        context.setFillColor(gray: 0.13, alpha: 1)
        context.addPath(
            CGPath(roundedRect: window, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.fillPath()

        var gauge = KnitGauge.standard
        gauge.rows = 6
        let theme = AppTheme(
            storedName: SharedDefaults.store.string(forKey: AppStorageKeys.General.theme) ?? "")
        let yarn = SweaterYarn.resolve(
            app: app, pattern: .byApp,
            basket: SweaterBaskets.basket(named: SweaterBaskets.defaultName), appTheme: theme)

        KnitRenderer.shared.draw(
            in: context, windowRect: window, radius: 5, band: 10, color: yarn.color,
            chart: yarn.chart, dim: 0, tuck: 1, stitch: .stockinette, anchor: .corner,
            gauge: gauge)

        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: size.width, height: size.height))
    }
}
