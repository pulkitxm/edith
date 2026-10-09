import CPDFium
import CoreGraphics
import Foundation

final class StudioPDFRasterizer {
    struct RenderedPage {
        let image: CGImage
        let dpi: Double
    }

    private static let queue: DispatchQueue = {
        FPDF_InitLibrary()
        return DispatchQueue(label: "com.pulkit.edith.pdf-rasterizer")
    }()

    private let document: OpaquePointer
    let pageCount: Int

    init(_ url: URL, password: String = "") throws {
        let secret = password.trimmingCharacters(in: .newlines)
        let loaded = try Self.queue.sync {
            guard let document = FPDF_LoadDocument(url.path, secret) else {
                if FPDF_GetLastError() == FPDF_ERR_PASSWORD {
                    throw secret.isEmpty
                        ? StudioError.needsPassword(url.lastPathComponent)
                        : StudioError.wrongPassword(url.lastPathComponent)
                }
                throw StudioError.unreadable(url.lastPathComponent)
            }
            return (document, Int(FPDF_GetPageCount(document)))
        }
        document = loaded.0
        pageCount = loaded.1
    }

    deinit {
        Self.queue.sync { FPDF_CloseDocument(document) }
    }

    func render(_ index: Int, dpi: Double, maxPixels: Int = 120_000_000) throws -> RenderedPage {
        guard dpi.isFinite, dpi > 0, maxPixels > 0 else {
            throw StudioError.invalidOption("resolution", "use a positive finite resolution")
        }
        return try Self.queue.sync {
            try Task.checkCancellation()
            guard index >= 0, index < pageCount,
                let page = FPDF_LoadPage(document, Int32(index))
            else { throw StudioError.failed("The PDF page could not be opened.") }
            defer { FPDF_ClosePage(page) }
            let size = CGSize(
                width: Double(FPDF_GetPageWidthF(page)), height: Double(FPDF_GetPageHeightF(page)))
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                throw StudioError.failed("The PDF page has an invalid size.")
            }
            let scale = min(dpi / 72, sqrt(Double(maxPixels) / (size.width * size.height)))
            let pixelWidth = max(1, (size.width * scale).rounded())
            let pixelHeight = max(1, (size.height * scale).rounded())
            guard pixelWidth <= Double(Int32.max), pixelHeight <= Double(Int32.max) else {
                throw StudioError.failed("The PDF page is too large to render.")
            }
            let width = Int(pixelWidth)
            let height = Int(pixelHeight)
            guard
                let bitmap = FPDFBitmap_Create(Int32(width), Int32(height), 0)
            else { throw StudioError.failed("Not enough memory to render the page.") }
            defer { FPDFBitmap_Destroy(bitmap) }
            FPDFBitmap_FillRect(bitmap, 0, 0, Int32(width), Int32(height), 0xFFFF_FFFF)
            let flags = Int32(FPDF_ANNOT)
            FPDF_RenderPageBitmap(bitmap, page, 0, 0, Int32(width), Int32(height), 0, flags)
            var formInfo = FPDF_FORMFILLINFO()
            formInfo.version = 1
            withUnsafeMutablePointer(to: &formInfo) { info in
                if let forms = FPDFDOC_InitFormFillEnvironment(document, info) {
                    FPDF_FFLDraw(forms, bitmap, page, 0, 0, Int32(width), Int32(height), 0, flags)
                    FPDFDOC_ExitFormFillEnvironment(forms)
                }
            }
            try Task.checkCancellation()
            let stride = Int(FPDFBitmap_GetStride(bitmap))
            guard let buffer = FPDFBitmap_GetBuffer(bitmap),
                let provider = CGDataProvider(
                    data: Data(bytes: buffer, count: stride * height) as CFData),
                let image = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                        CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                )
            else { throw StudioError.failed("The PDF page could not be rendered.") }
            return RenderedPage(image: image, dpi: scale * 72)
        }
    }
}
