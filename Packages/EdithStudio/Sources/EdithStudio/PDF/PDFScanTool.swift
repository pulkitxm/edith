import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PDFKit
import Vision

enum DocumentScan {
    static let tool = StudioTool(
        id: "pdf.scan", title: "Scan to PDF",
        summary: "Turn photos of paper into straight, clean PDF pages, like a document scanner.",
        symbol: "doc.viewfinder", group: .convert, inputs: [.image],
        arity: .combine(minimum: 1, maximum: nil), produces: .kind(.pdf),
        options: [
            .choice(
                "look", "Look",
                [
                    StudioChoice("color", "Color"), StudioChoice("gray", "Grayscale"),
                    StudioChoice("mono", "Black and white"),
                    StudioChoice("original", "As photographed"),
                ], default: "color"),
            .toggle(
                "straighten", "Find the page and straighten it", default: true,
                help: "Crops to the paper and corrects the angle it was photographed at."),
            .choice(
                "paper", "Page size",
                [StudioChoice("fit", "Same as the scan")] + StudioPaperSize.choices, default: "a4"),
            .toggle("ocr", "Make the text searchable", default: true),
        ],
        keywords: ["scan", "scanner", "camera", "photo", "document", "receipt", "whiteboard"],
        actionTitle: "Scan to PDF", family: .pdf
    ) { run in
        let folder = try run.scratch("pages")
        var pages: [URL] = []
        var straightened = 0
        for (index, input) in run.inputs.enumerated() {
            try run.checkCancellation()
            run.status("Scanning \(input.lastPathComponent)")
            let photo = try StudioImageIO.load(input, maxPixelSize: 4200)
            var page = photo
            if run.settings.bool("straighten"), let corrected = try straighten(photo) {
                page = corrected
                straightened += 1
            }
            page = enhance(page, look: run.settings.text("look")) ?? page
            let file = folder.appendingPathComponent(String(format: "page-%03d.jpg", index + 1))
            try StudioImageIO.write(page, to: file, format: .jpeg, options: .init(quality: 0.85))
            pages.append(file)
            run.progress(Double(index + 1) / Double(run.inputs.count) * 0.6)
        }
        var layout = ImagesToPDF.Layout()
        layout.paper = StudioPaperSize(rawValue: run.settings.text("paper"))
        layout.margin = 0
        let scanned =
            run.settings.bool("ocr")
            ? folder.appendingPathComponent("scan.pdf")
            : run.output(for: run.inputs[0], suffix: "scan", ext: "pdf")
        try ImagesToPDF.write(pages, layout: layout, to: scanned) { run.progress(0.6 + $0 * 0.1) }
        let missed = run.inputs.count - straightened
        if missed > 0, run.settings.bool("straighten") {
            run.note(
                "No page edges were found in \(missed) photo\(missed == 1 ? "" : "s"), so "
                    + "\(missed == 1 ? "it was" : "they were") kept whole.")
        }
        guard run.settings.bool("ocr") else { return [scanned] }
        let document = try StudioPDF.open(scanned)
        var layers: [Int: [StudioPDF.TextLine]] = [:]
        for index in 0..<document.pageCount {
            try run.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            run.status("Reading page \(index + 1) of \(document.pageCount)")
            layers[index] = try PDFOptimizeTools.recognizedLines(on: page)
            run.progress(0.7 + Double(index + 1) / Double(document.pageCount) * 0.25)
        }
        let output = run.output(for: run.inputs[0], suffix: "scan", ext: "pdf")
        try StudioPDF.rebuild(
            document, to: output, pages: Set(layers.keys),
            over: { canvas in
                StudioPDF.drawInvisibleText(layers[canvas.index] ?? [], in: canvas.context)
            }, progress: { run.progress(0.95 + $0 * 0.05) })
        return [output]
    }

    static func straighten(_ image: CGImage) throws -> CGImage? {
        guard let quad = try pageCorners(in: image)?.inset(by: 0.012) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
        }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = CIImage(cgImage: image)
        filter.topLeft = point(quad.topLeft)
        filter.topRight = point(quad.topRight)
        filter.bottomLeft = point(quad.bottomLeft)
        filter.bottomRight = point(quad.bottomRight)
        guard let output = filter.outputImage else { return nil }
        return StudioImageOps.render(output)
    }

    struct Quad {
        let topLeft: CGPoint
        let topRight: CGPoint
        let bottomLeft: CGPoint
        let bottomRight: CGPoint

        var area: CGFloat {
            let points = [topLeft, topRight, bottomRight, bottomLeft]
            var sum: CGFloat = 0
            for index in 0..<4 {
                let a = points[index]
                let b = points[(index + 1) % 4]
                sum += a.x * b.y - b.x * a.y
            }
            return abs(sum) / 2
        }

        func inset(by fraction: CGFloat) -> Quad {
            let center = CGPoint(
                x: (topLeft.x + topRight.x + bottomLeft.x + bottomRight.x) / 4,
                y: (topLeft.y + topRight.y + bottomLeft.y + bottomRight.y) / 4)
            func pull(_ point: CGPoint) -> CGPoint {
                CGPoint(
                    x: point.x + (center.x - point.x) * fraction * 2,
                    y: point.y + (center.y - point.y) * fraction * 2)
            }
            return Quad(
                topLeft: pull(topLeft), topRight: pull(topRight), bottomLeft: pull(bottomLeft),
                bottomRight: pull(bottomRight))
        }
    }

    static func pageCorners(in image: CGImage) throws -> Quad? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let segmentation = VNDetectDocumentSegmentationRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumSize = 0.3
        rectangles.minimumAspectRatio = 0.2
        rectangles.maximumAspectRatio = 1
        rectangles.quadratureTolerance = 30
        rectangles.maximumObservations = 1
        try handler.perform([segmentation, rectangles])
        func quad(_ observation: VNRectangleObservation?) -> Quad? {
            guard let observation, observation.confidence >= 0.5 else { return nil }
            let quad = Quad(
                topLeft: observation.topLeft, topRight: observation.topRight,
                bottomLeft: observation.bottomLeft, bottomRight: observation.bottomRight)
            return quad.area > 0.12 && quad.area < 0.985 ? quad : nil
        }
        let page = quad(segmentation.results?.first)
        let rectangle = quad(rectangles.results?.first)
        guard let page else { return rectangle }
        guard let rectangle, rectangle.area >= page.area * 0.8 else { return page }
        return rectangle
    }

    static func enhance(_ image: CGImage, look: String) -> CGImage? {
        let input = CIImage(cgImage: image)
        var output: CIImage
        switch look {
        case "original":
            return image
        case "gray":
            let enhancer = CIFilter.documentEnhancer()
            enhancer.inputImage = input
            enhancer.amount = 1
            let controls = CIFilter.colorControls()
            controls.inputImage = enhancer.outputImage ?? input
            controls.saturation = 0
            controls.contrast = 1.15
            output = controls.outputImage ?? input
        case "mono":
            let controls = CIFilter.colorControls()
            controls.inputImage = input
            controls.saturation = 0
            let threshold = CIFilter.colorThresholdOtsu()
            threshold.inputImage = controls.outputImage ?? input
            output = threshold.outputImage ?? input
        default:
            let enhancer = CIFilter.documentEnhancer()
            enhancer.inputImage = input
            enhancer.amount = 1
            output = enhancer.outputImage ?? input
        }
        return StudioImageOps.render(output, extent: input.extent)
    }
}
