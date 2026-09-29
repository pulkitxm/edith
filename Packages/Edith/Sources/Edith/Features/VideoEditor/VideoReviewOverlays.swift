import CoreGraphics
import CoreText
import Foundation

extension VideoEditorService {
    public struct ReviewOverlays: Sendable {
        public var showBeatMarkers = false
        public var waveformAssetID: String?
        public var waveformMapping: AudioMarkerMapping?

        public init() {}

        var enabled: Bool {
            showBeatMarkers || waveformAssetID != nil || waveformMapping != nil
        }
    }

    public struct ReviewOverlayReport: Codable, Sendable {
        public struct WaveformSpan: Codable, Sendable {
            public let sourceStartSeconds: Double
            public let sourceEndSeconds: Double
            public let outputStartSeconds: Double
            public let outputEndSeconds: Double
            public let xStart: Double
            public let xEnd: Double
            public let sourcePeak: Float
        }

        public struct MarkerPosition: Codable, Sendable {
            public let id: String
            public let frame: Int64
            public let frameRate: VideoMarkerFrameRate
            public let kind: VideoMarker.Kind
            public let outputSeconds: Double
            public let x: Double
        }

        public struct CellPosition: Codable, Sendable {
            public let cell: Int
            public let frame: Int64
            public let outputSeconds: Double
            public let x: Double
        }

        public let positionUnit: String
        public let pixelOrigin: String
        public let stripHeight: Int
        public let axisLeft: Double
        public let axisWidth: Double
        public let outputDurationSeconds: Double
        public let waveformAssetID: String?
        public let waveformMapping: AudioMarkerMapping?
        public let waveformSampleRateHz: Double?
        public let waveformAmplitudeUnit: String
        public let waveform: [WaveformSpan]
        public let markers: [MarkerPosition]
        public let cells: [CellPosition]
    }

    static func reviewOverlayAnalysis(
        project: VideoProject, options: ReviewOverlays, pipeline: VideoRenderPipeline
    ) async throws -> AudioAnalysisReport? {
        guard options.waveformAssetID != nil || options.waveformMapping != nil else { return nil }
        guard let asset = options.waveformAssetID, let mapping = options.waveformMapping else {
            throw Failure(
                "invalid_mapping",
                "A waveform requires a selected audio asset and all four mapping values.")
        }
        let duration = pipeline.videoComposition.frameDuration
        do {
            return try await analyzeAudio(
                project, assetID: asset, mapping: mapping,
                rate: .explicit(
                    VideoMarkerFrameRate(
                        numerator: Int(duration.timescale), denominator: Int(duration.value))))
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure("invalid_audio", error.localizedDescription)
        }
    }

    static func reviewOverlayGeometry(
        options: ReviewOverlays, analysis: AudioAnalysisReport?, markers: [VideoMarker],
        frames: [ReviewFrame], duration: Double, sheetWidth: Int
    ) throws -> ReviewOverlayReport {
        let left = 12.0
        let width = Double(sheetWidth) - 24
        func x(_ seconds: Double) -> Double { left + seconds / duration * width }
        let selectedMarkers =
            options.showBeatMarkers ? markers.filter { $0.seconds < duration } : []
        try require(
            selectedMarkers.count <= 10_000,
            "Contact sheet overlays support up to 10000 visible saved markers.")
        let spans: [ReviewOverlayReport.WaveformSpan]
        if let analysis, let mapping = analysis.mapping {
            let sourceEnd = min(
                mapping.sourceOutSeconds,
                mapping.sourceInSeconds + (duration - mapping.outputStartSeconds)
                    * mapping.playbackRate)
            spans = analysis.analysis.waveform.compactMap { bin in
                let start = max(
                    mapping.sourceInSeconds, Double(bin.startSample) / analysis.analysis.sampleRate)
                let end = min(
                    sourceEnd,
                    Double(bin.startSample + bin.sampleCount) / analysis.analysis.sampleRate)
                guard end > start else { return nil }
                let outputStart =
                    mapping.outputStartSeconds + (start - mapping.sourceInSeconds)
                    / mapping.playbackRate
                let outputEnd = min(
                    duration,
                    mapping.outputStartSeconds + (end - mapping.sourceInSeconds)
                        / mapping.playbackRate)
                return .init(
                    sourceStartSeconds: start, sourceEndSeconds: end,
                    outputStartSeconds: outputStart, outputEndSeconds: outputEnd,
                    xStart: x(outputStart), xEnd: x(outputEnd), sourcePeak: bin.peak)
            }
            try require(
                !spans.isEmpty, "Selected audio mapping does not overlap the output timeline.")
        } else {
            spans = []
        }
        return ReviewOverlayReport(
            positionUnit: "output_seconds", pixelOrigin: "left_edge", stripHeight: 132,
            axisLeft: left, axisWidth: width, outputDurationSeconds: duration,
            waveformAssetID: analysis?.assetID, waveformMapping: analysis?.mapping,
            waveformSampleRateHz: analysis?.analysis.sampleRate,
            waveformAmplitudeUnit: "source_linear_peak_before_mix", waveform: spans,
            markers: selectedMarkers.map {
                .init(
                    id: $0.id, frame: $0.frame, frameRate: $0.frameRate, kind: $0.kind,
                    outputSeconds: $0.seconds, x: x($0.seconds))
            },
            cells: frames.enumerated().map {
                .init(
                    cell: $0.offset + 1, frame: $0.element.frame,
                    outputSeconds: $0.element.time, x: x($0.element.time))
            })
    }

    static func drawReviewOverlay(_ report: ReviewOverlayReport, in context: CGContext) {
        let left = report.axisLeft
        let width = report.axisWidth
        let cyan = CGColor(red: 0.25, green: 0.8, blue: 1, alpha: 1)
        let orange = CGColor(red: 1, green: 0.65, blue: 0.2, alpha: 1)
        let pink = CGColor(red: 1, green: 0.4, blue: 0.65, alpha: 1)
        context.saveGState()
        context.clip(to: CGRect(x: left, y: 0, width: width, height: Double(report.stripHeight)))
        func label(_ text: String, y: Double, color: CGColor) {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String):
                            CTFontCreateWithName("Menlo" as CFString, 10, nil),
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                    ]))
            let size = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.saveGState()
            context.translateBy(x: left, y: y)
            context.scaleBy(x: min(1, width / max(1, size)), y: 1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.setStrokeColor(CGColor(gray: 0.4, alpha: 1))
        context.move(to: CGPoint(x: left, y: 68))
        context.addLine(to: CGPoint(x: left + width, y: 68))
        context.strokePath()
        context.setFillColor(cyan)
        for span in report.waveform {
            let height = max(1, Double(span.sourcePeak) * 36)
            context.fill(
                CGRect(
                    x: span.xStart, y: 68 - height / 2,
                    width: max(0.5, span.xEnd - span.xStart), height: height))
        }
        for marker in report.markers {
            context.setFillColor(marker.kind == .transient ? orange : pink)
            context.fill(CGRect(x: marker.x - 0.5, y: 45, width: 1, height: 46))
        }
        context.setFillColor(cyan)
        for cell in report.cells {
            context.fill(CGRect(x: cell.x - 0.5, y: 95, width: 1, height: 9))
        }
        label(
            String(format: "output: 0 to %.3f s", report.outputDurationSeconds), y: 114,
            color: CGColor(gray: 0.9, alpha: 1))
        label("cyan ticks: review cells (\(report.cells.count))", y: 32, color: cyan)
        label("pink: manual / orange: saved transient", y: 20, color: orange)
        label(
            report.waveformAssetID == nil
                ? "saved markers on output time" : "waveform: mapped source peak, before mix",
            y: 8, color: CGColor(gray: 0.9, alpha: 1))
        context.restoreGState()
    }
}
