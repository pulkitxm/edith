import CoreGraphics
import CoreImage
import Foundation
import Vision

public enum StudioVision {
    public struct RecognizedLine: Sendable, Equatable {
        public let text: String
        public let box: CGRect
        public let confidence: Float
    }

    public static let languageChoices: [StudioChoice] = [
        StudioChoice("auto", "Automatic"), StudioChoice("en-US", "English"),
        StudioChoice("es-ES", "Spanish"), StudioChoice("fr-FR", "French"),
        StudioChoice("de-DE", "German"), StudioChoice("it-IT", "Italian"),
        StudioChoice("pt-BR", "Portuguese"), StudioChoice("nl-NL", "Dutch"),
        StudioChoice("zh-Hans", "Chinese, Simplified"),
        StudioChoice("zh-Hant", "Chinese, Traditional"),
        StudioChoice("ja-JP", "Japanese"), StudioChoice("ko-KR", "Korean"),
        StudioChoice("ru-RU", "Russian"), StudioChoice("uk-UA", "Ukrainian"),
        StudioChoice("ar-SA", "Arabic"), StudioChoice("th-TH", "Thai"),
        StudioChoice("vi-VT", "Vietnamese"),
    ]

    public static func recognizeText(
        in image: CGImage, language: String = "auto", accurate: Bool = true
    ) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = accurate
        if language == "auto" {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = [language]
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedLine(
                text: text, box: observation.boundingBox, confidence: candidate.confidence)
        }
    }

    public static func text(of lines: [RecognizedLine]) -> String {
        let sorted = lines.sorted {
            abs($0.box.midY - $1.box.midY) > min($0.box.height, $1.box.height) * 0.5
                ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX
        }
        var output: [String] = []
        var previous: RecognizedLine?
        for line in sorted {
            if let last = previous,
                abs(last.box.midY - line.box.midY) <= min(last.box.height, line.box.height) * 0.5
            {
                output[output.count - 1] += "  " + line.text
            } else {
                if let last = previous, last.box.minY - line.box.maxY > last.box.height * 1.2 {
                    output.append("")
                }
                output.append(line.text)
            }
            previous = line
        }
        return output.joined(separator: "\n")
    }

    public static func faces(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).map(\.boundingBox)
    }

    public static func textRegions(in image: CGImage) throws -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).map(\.boundingBox)
    }

    public static func foregroundMask(of image: CGImage) throws -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first else { return nil }
        let buffer = try result.generateScaledMaskForImage(
            forInstances: result.allInstances, from: handler)
        return CIImage(cvPixelBuffer: buffer)
    }

    public static func pixelRect(
        _ normalized: CGRect, in size: CGSize, expandedBy fraction: Double = 0
    )
        -> CGRect
    {
        let rect = CGRect(
            x: normalized.minX * size.width, y: normalized.minY * size.height,
            width: normalized.width * size.width, height: normalized.height * size.height)
        return rect.insetBy(dx: -rect.width * fraction, dy: -rect.height * fraction)
    }
}
