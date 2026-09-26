import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PDFImageTools {
    static var all: [StudioTool] { [toImages, fromImages].map { $0.checkingChoices() } }

    static let toImages = StudioTool(
        id: "pdf.to-images", title: "PDF to JPG",
        summary: "Turn each page into an image, or pull out every image inside the PDF.",
        symbol: "photo.on.rectangle", group: .convert, inputs: [.pdf], produces: .kind(.image),
        options: [
            .choice(
                "mode", "Convert",
                [
                    StudioChoice("pages", "Pages to images"),
                    StudioChoice("extract", "Extract images"),
                ],
                default: "pages"),
            .choice(
                "format", "Format",
                [
                    StudioChoice("jpg", "JPG"), StudioChoice("png", "PNG"),
                    StudioChoice("heic", "HEIC"), StudioChoice("tiff", "TIFF"),
                ], default: "jpg", when: .init("mode", ["pages"])),
            .choice(
                "dpi", "Resolution",
                [
                    StudioChoice("72", "72 dpi"), StudioChoice("150", "150 dpi"),
                    StudioChoice("300", "300 dpi"), StudioChoice("600", "600 dpi"),
                ], default: "150", when: .init("mode", ["pages"])),
            .percent(
                "quality", "Quality", 0.3...1, default: 0.85,
                when: .init("format", ["jpg", "heic"])),
            .pages(when: .init("mode", ["pages"])),
            PDFOrganizeTools.passwordOption,
        ],
        keywords: ["jpeg", "png", "export", "images", "extract", "pictures"], groupsOutputs: true,
        actionTitle: "Convert"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        if run.settings.text("mode") == "extract" {
            let folder = run.workDirectory
            let files = try PDFImageExtractor.extract(
                from: document, stem: run.input.studioStem, into: folder
            ) { run.progress($0) }
            guard !files.isEmpty else {
                throw StudioError.nothingToDo("This PDF has no embedded images to extract.")
            }
            return files
        }
        let format = StudioImageFormat(rawValue: run.settings.text("format")) ?? .jpeg
        let dpi = Double(run.settings.text("dpi")) ?? 150
        let pages = try StudioPageSelection.pages(
            run.settings.text("pages"), pageCount: document.pageCount)
        let width = String(document.pageCount).count
        var outputs: [URL] = []
        for (step, index) in pages.enumerated() {
            try run.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            run.status("Rendering page \(index + 1)")
            let image = try StudioPDF.render(page, dpi: dpi)
            let label = "page-" + String(format: "%0\(width)d", index + 1)
            let output = run.output(for: run.input, suffix: label, ext: format.fileExtension)
            try StudioImageIO.write(
                image, to: output, format: format,
                options: .init(quality: run.settings.number("quality"), dpi: dpi))
            outputs.append(output)
            run.progress(Double(step + 1) / Double(pages.count))
        }
        return outputs
    }

    static let fromImages = StudioTool(
        id: "pdf.from-images", title: "JPG to PDF",
        summary: "Make a PDF from photos and scans with the page size and margins you want.",
        symbol: "doc.badge.plus", group: .convert, inputs: [.image],
        arity: .combine(minimum: 1, maximum: nil), produces: .kind(.pdf),
        options: [
            .choice(
                "paper", "Page size",
                [StudioChoice("fit", "Same as image")] + StudioPaperSize.choices, default: "a4"),
            .choice(
                "orientation", "Orientation",
                [
                    StudioChoice("auto", "Automatic"), StudioChoice("portrait", "Portrait"),
                    StudioChoice("landscape", "Landscape"),
                ], default: "auto"),
            .choice(
                "margin", "Margin",
                [
                    StudioChoice("0", "None"), StudioChoice("20", "Small"),
                    StudioChoice("48", "Large"),
                ], default: "20"),
            .toggle("combine", "Put all images in one PDF", default: true),
        ],
        keywords: ["images", "photos", "scan", "png", "heic", "convert"], actionTitle: "Convert",
        family: .pdf
    ) { run in
        var layout = ImagesToPDF.Layout()
        layout.paper = StudioPaperSize(rawValue: run.settings.text("paper"))
        layout.orientation = run.settings.text("orientation")
        layout.margin = Double(run.settings.text("margin")) ?? 20
        if run.settings.bool("combine") {
            let output = run.output(for: run.inputs[0], suffix: nil, ext: "pdf")
            try ImagesToPDF.write(run.inputs, layout: layout, to: output) { run.progress($0) }
            return [output]
        }
        var outputs: [URL] = []
        for (index, input) in run.inputs.enumerated() {
            let output = run.output(for: input, suffix: nil, ext: "pdf")
            try ImagesToPDF.write([input], layout: layout, to: output) { _ in }
            outputs.append(output)
            run.progress(Double(index + 1) / Double(run.inputs.count))
        }
        return outputs
    }
}

public enum ImagesToPDF {
    public struct Layout: Sendable {
        public var paper: StudioPaperSize? = .a4
        public var orientation = "auto"
        public var margin = 20.0

        public init() {}

        func pageSize(for image: CGSize) -> CGSize {
            guard let paper else { return image }
            let base = paper.points
            let landscape: Bool
            switch orientation {
            case "portrait": landscape = false
            case "landscape": landscape = true
            default: landscape = image.width > image.height
            }
            return landscape ? CGSize(width: base.height, height: base.width) : base
        }
    }

    public static func page(for image: CGImage, layout: Layout) -> PDFPage? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        var box = CGRect(origin: .zero, size: layout.pageSize(for: points(size, dpi: 72)))
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPage(mediaBox: &box)
        draw(image, in: box, margin: layout.paper == nil ? 0 : layout.margin, context: context)
        context.endPage()
        context.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    static func points(_ pixels: CGSize, dpi: Double) -> CGSize {
        CGSize(width: pixels.width * 72 / dpi, height: pixels.height * 72 / dpi)
    }

    static func draw(_ image: CGImage, in box: CGRect, margin: Double, context: CGContext) {
        let area = box.insetBy(dx: margin, dy: margin)
        let scale = min(area.width / Double(image.width), area.height / Double(image.height))
        let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        let frame = CGRect(
            x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width,
            height: size.height)
        context.interpolationQuality = .high
        context.draw(image, in: frame)
    }

    public static func write(
        _ urls: [URL], layout: Layout, to output: URL, progress: (Double) -> Void
    ) throws {
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw StudioError.failed("Could not create \(output.lastPathComponent).")
        }
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let image = try passthroughImage(url) ?? StudioImageIO.load(url)
            let dpi = StudioImageIO.info(url)?.dpi ?? 72
            let natural = points(
                CGSize(width: image.width, height: image.height), dpi: max(dpi, 72))
            var box = CGRect(origin: .zero, size: layout.pageSize(for: natural))
            context.beginPage(mediaBox: &box)
            draw(image, in: box, margin: layout.paper == nil ? 0 : layout.margin, context: context)
            context.endPage()
            progress(Double(index + 1) / Double(urls.count))
        }
        context.closePDF()
    }

    static func passthroughImage(_ url: URL) throws -> CGImage? {
        guard StudioImageFormat.of(url) == .jpeg else { return nil }
        let orientation = StudioImageIO.properties(url)[kCGImagePropertyOrientation] as? UInt32 ?? 1
        guard orientation == 1, let provider = CGDataProvider(url: url as CFURL) else { return nil }
        return CGImage(
            jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }
}

enum PDFImageExtractor {
    static func extract(
        from document: PDFDocument, stem: String, into folder: URL, progress: (Double) -> Void
    ) throws -> [URL] {
        var outputs: [URL] = []
        var seen = Set<Int>()
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index)?.pageRef,
                let resources = page.dictionary.flatMap({ dictionary($0, "Resources") })
            else { continue }
            var counter = 0
            try collect(
                resources, depth: 0, seen: &seen
            ) { image in
                counter += 1
                let name = "\(stem)-p\(index + 1)-\(counter).\(image.ext)"
                let url = StudioNaming.unique(folder.appendingPathComponent(name))
                try image.data.write(to: url)
                outputs.append(url)
            }
            progress(Double(index + 1) / Double(document.pageCount))
        }
        return outputs
    }

    struct Extracted {
        let data: Data
        let ext: String
    }

    static func collect(
        _ resources: CGPDFDictionaryRef, depth: Int, seen: inout Set<Int>,
        emit: (Extracted) throws -> Void
    ) throws {
        guard depth < 6, let objects = dictionary(resources, "XObject") else { return }
        var names: [String] = []
        CGPDFDictionaryApplyBlock(
            objects,
            { key, _, _ in
                names.append(String(cString: key))
                return true
            }, nil)
        for name in names {
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(objects, name, &stream), let stream,
                let info = CGPDFStreamGetDictionary(stream)
            else { continue }
            let identity = unsafeBitCast(stream, to: Int.self)
            guard seen.insert(identity).inserted else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(info, "Subtype", &subtype), let subtype else { continue }
            switch String(cString: subtype) {
            case "Image":
                if let image = decode(stream, info: info) { try emit(image) }
            case "Form":
                if let nested = dictionary(info, "Resources") {
                    try collect(nested, depth: depth + 1, seen: &seen, emit: emit)
                }
            default:
                continue
            }
        }
    }

    static func dictionary(_ parent: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(parent, key, &value) ? value : nil
    }

    static func integer(_ parent: CGPDFDictionaryRef, _ key: String) -> Int? {
        var value: CGPDFInteger = 0
        return CGPDFDictionaryGetInteger(parent, key, &value) ? Int(value) : nil
    }

    static func decode(_ stream: CGPDFStreamRef, info: CGPDFDictionaryRef) -> Extracted? {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, !data.isEmpty else {
            return nil
        }
        let mask = softMask(info)
        if mask == nil {
            switch format {
            case .jpegEncoded: return Extracted(data: data, ext: "jpg")
            case .JPEG2000: return Extracted(data: data, ext: "jp2")
            default: break
            }
        }
        let decoded: CGImage?
        switch format {
        case .jpegEncoded, .JPEG2000:
            decoded = CGImageSourceCreateWithData(data as CFData, nil).flatMap {
                CGImageSourceCreateImageAtIndex($0, 0, nil)
            }
        default:
            decoded = raw(data, info: info)
        }
        guard var image = decoded else { return nil }
        if let mask, let masked = apply(mask, to: image) { image = masked }
        guard let png = try? StudioImageIO.encode(image, format: .png) else { return nil }
        return Extracted(data: png, ext: "png")
    }

    static func raw(_ data: Data, info: CGPDFDictionaryRef) -> CGImage? {
        guard let width = integer(info, "Width"), let height = integer(info, "Height"),
            width > 0, height > 0
        else { return nil }
        let bits = integer(info, "BitsPerComponent") ?? 8
        guard bits == 8 || bits == 1 else { return nil }
        let (space, components) = colorSpace(info)
        guard let space else { return nil }
        let bytesPerRow = bits == 1 ? (width + 7) / 8 : width * components
        guard data.count >= bytesPerRow * height,
            let provider = CGDataProvider(data: data as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: bits,
            bitsPerPixel: bits * components, bytesPerRow: bytesPerRow, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func softMask(_ info: CGPDFDictionaryRef) -> (data: Data, width: Int, height: Int)? {
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(info, "SMask", &stream), let stream,
            let maskInfo = CGPDFStreamGetDictionary(stream),
            let width = integer(maskInfo, "Width"), let height = integer(maskInfo, "Height"),
            (integer(maskInfo, "BitsPerComponent") ?? 8) == 8
        else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw,
            data.count >= width * height
        else { return nil }
        return (data, width, height)
    }

    static func apply(_ mask: (data: Data, width: Int, height: Int), to image: CGImage) -> CGImage?
    {
        let width = mask.width
        let height = mask.height
        guard let context = StudioImageOps.context(width: width, height: height),
            let base = context.data
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = base.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        mask.data.withUnsafeBytes { raw in
            let alpha = raw.bindMemory(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<width {
                    let value = Int(alpha[row * width + column])
                    let offset = row * context.bytesPerRow + column * 4
                    for channel in 0..<3 {
                        pixels[offset + channel] = UInt8(
                            Int(pixels[offset + channel]) * value / 255)
                    }
                    pixels[offset + 3] = UInt8(value)
                }
            }
        }
        return context.makeImage()
    }

    static func colorSpace(_ info: CGPDFDictionaryRef) -> (CGColorSpace?, Int) {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(info, "ColorSpace", &name), let name {
            switch String(cString: name) {
            case "DeviceGray", "CalGray": return (CGColorSpaceCreateDeviceGray(), 1)
            case "DeviceRGB", "CalRGB": return (CGColorSpace(name: CGColorSpace.sRGB), 3)
            case "DeviceCMYK": return (CGColorSpaceCreateDeviceCMYK(), 4)
            default: return (nil, 0)
            }
        }
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(info, "ColorSpace", &array), let array {
            var family: UnsafePointer<CChar>?
            guard CGPDFArrayGetName(array, 0, &family), let family,
                String(cString: family) == "ICCBased"
            else { return (nil, 0) }
            var profile: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, 1, &profile), let profile,
                let profileInfo = CGPDFStreamGetDictionary(profile)
            else { return (nil, 0) }
            switch integer(profileInfo, "N") {
            case 1: return (CGColorSpaceCreateDeviceGray(), 1)
            case 3: return (CGColorSpace(name: CGColorSpace.sRGB), 3)
            case 4: return (CGColorSpaceCreateDeviceCMYK(), 4)
            default: return (nil, 0)
            }
        }
        var imageMask: CGPDFBoolean = 0
        if CGPDFDictionaryGetBoolean(info, "ImageMask", &imageMask), imageMask != 0 {
            return (CGColorSpaceCreateDeviceGray(), 1)
        }
        return (nil, 0)
    }
}
