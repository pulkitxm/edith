import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum StudioImageOps {
    public static let ciContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false,
    ])

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func context(width: Int, height: Int, opaque: Bool = false) -> CGContext? {
        CGContext(
            data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8,
            bytesPerRow: 0, space: sRGB,
            bitmapInfo: opaque
                ? CGImageAlphaInfo.noneSkipLast.rawValue
                : CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    public static func render(_ image: CIImage, extent: CGRect? = nil) -> CGImage? {
        let rect = (extent ?? image.extent).integral
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
            return nil
        }
        return ciContext.createCGImage(image, from: rect, format: .RGBA8, colorSpace: sRGB)
    }

    public static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let input = CIImage(cgImage: image)
        let minimum = CIFilter.areaMinimum()
        minimum.inputImage = input
        minimum.extent = input.extent
        guard let output = minimum.outputImage else { return true }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil)
        return pixel[3] < 250
    }

    public static func flatten(_ image: CGImage, on color: StudioColor) -> CGImage? {
        guard let context = context(width: image.width, height: image.height, opaque: true) else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(color.cgColor)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    public static func grayscale(_ image: CGImage) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    public static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        if width == image.width && height == image.height { return image }
        let downscale = width < image.width && height < image.height
        if downscale {
            let input = CIImage(cgImage: image).clampedToExtent()
            let scale = Double(height) / Double(image.height)
            let aspect = (Double(width) / Double(image.width)) / scale
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = input
            filter.scale = Float(scale)
            filter.aspectRatio = Float(aspect)
            if let output = filter.outputImage,
                let rendered = render(
                    output.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)))
            {
                return rendered
            }
        }
        guard let context = context(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    public static func fitted(_ image: CGImage, maxDimension: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard maxDimension > 0, longest > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(longest)
        return resized(
            image, width: max(1, Int((Double(image.width) * scale).rounded())),
            height: max(1, Int((Double(image.height) * scale).rounded()))) ?? image
    }

    public static func cropped(_ image: CGImage, to rect: StudioRect) -> CGImage? {
        let pixels = rect.pixels(in: CGSize(width: image.width, height: image.height))
        return image.cropping(to: pixels)
    }

    public static func squared(_ image: CGImage) -> CGImage? {
        let side = max(image.width, image.height)
        guard let context = context(width: side, height: side) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(
                x: (side - image.width) / 2, y: (side - image.height) / 2, width: image.width,
                height: image.height))
        return context.makeImage()
    }

    public static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let swapSides = turns % 2 == 1
        let width = swapSides ? image.height : image.width
        let height = swapSides ? image.width : image.height
        guard let context = context(width: width, height: height) else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }

    public static func rotated(_ image: CGImage, degrees: Double, fill: StudioColor?) -> CGImage? {
        let radians = degrees * .pi / 180
        let input = CIImage(cgImage: image)
        let output = input.transformed(by: CGAffineTransform(rotationAngle: -radians))
        let extent = output.extent.integral
        var composed = output.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if let fill {
            let background = CIImage(color: CIColor(cgColor: fill.cgColor)).cropped(
                to: CGRect(origin: .zero, size: extent.size))
            composed = composed.composited(over: background)
        }
        return render(composed, extent: CGRect(origin: .zero, size: extent.size))
    }

    public static func flipped(_ image: CGImage, horizontal: Bool, vertical: Bool) -> CGImage? {
        guard horizontal || vertical else { return image }
        guard let context = context(width: image.width, height: image.height) else { return nil }
        context.translateBy(
            x: horizontal ? CGFloat(image.width) : 0, y: vertical ? CGFloat(image.height) : 0)
        context.scaleBy(x: horizontal ? -1 : 1, y: vertical ? -1 : 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    public static func contentBounds(
        _ image: CGImage, threshold: UInt8 = 245
    ) -> CGRect? {
        let width = min(image.width, 600)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        guard let context = context(width: width, height: height, opaque: true) else {
            return nil
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * context.bytesPerRow + column * 4
                if bytes[offset] < threshold || bytes[offset + 1] < threshold
                    || bytes[offset + 2] < threshold
                {
                    minX = min(minX, column)
                    maxX = max(maxX, column)
                    minY = min(minY, row)
                    maxY = max(maxY, row)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: Double(minX) / Double(width), y: Double(minY) / Double(height),
            width: Double(maxX - minX + 1) / Double(width),
            height: Double(maxY - minY + 1) / Double(height))
    }

    public static func inkCoverage(_ image: CGImage, darkerThan threshold: UInt8 = 200) -> Double {
        let width = min(image.width, 800)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        guard let context = context(width: width, height: height, opaque: true) else { return 1 }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return 1 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var dark = 0
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * context.bytesPerRow + column * 4
                let luminance =
                    (Int(bytes[offset]) * 3 + Int(bytes[offset + 1]) * 6 + Int(bytes[offset + 2]))
                    / 10
                if luminance < Int(threshold) { dark += 1 }
            }
        }
        return Double(dark) / Double(width * height)
    }

    public static func isBlank(_ image: CGImage, tolerance: Double = 0.00008) -> Bool {
        inkCoverage(image) < tolerance
    }
}
