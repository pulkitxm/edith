import Foundation

extension VideoEditorService {
    public struct AudioAnalysisOptions: Sendable {
        public var sensitivity = 0.5
        public var refractorySeconds = 0.08
        public var minimumSpacingSeconds = 0.15
        public var maximumWaveformBins = 2048
        public var maximumTransients = 10_000
        public init() {}
    }

    public struct AudioMarkerMapping: Codable, Sendable {
        public let sourceInSeconds: Double
        public let sourceOutSeconds: Double
        public let outputStartSeconds: Double
        public let playbackRate: Double

        public init(
            sourceInSeconds: Double, sourceOutSeconds: Double, outputStartSeconds: Double,
            playbackRate: Double
        ) {
            self.sourceInSeconds = sourceInSeconds
            self.sourceOutSeconds = sourceOutSeconds
            self.outputStartSeconds = outputStartSeconds
            self.playbackRate = playbackRate
        }
    }

    public struct MarkerDocument: Codable, Sendable {
        public let version: Int
        public let markers: [VideoMarker]
    }

    public struct AudioAnalysisReport: Codable, Sendable {
        public let version: Int
        public let assetID: String
        public let sourcePath: String
        public let samplePositionUnit: String
        public let sampleRateUnit: String
        public let durationSeconds: Double
        public let analysis: VideoBeatAnalysis.Result
        public let mapping: AudioMarkerMapping?
        public let frameRate: VideoMarkerFrameRate?
        public let markerDocument: MarkerDocument?
    }

    public static func analyzeAudio(
        _ url: URL, assetID: String, options: AudioAnalysisOptions = .init(),
        mapping: AudioMarkerMapping? = nil, rate: MarkerRate? = nil
    ) async throws -> AudioAnalysisReport {
        try await analyzeAudio(
            open(url), assetID: assetID, options: options, mapping: mapping, rate: rate)
    }

    static func analyzeAudio(
        _ project: VideoProject, assetID: String, options: AudioAnalysisOptions = .init(),
        mapping: AudioMarkerMapping? = nil, rate: MarkerRate? = nil
    ) async throws -> AudioAnalysisReport {
        try require(
            (mapping == nil) == (rate == nil),
            "Mapping and an FPS choice must be supplied together.")
        let sourceAssetID =
            project.audioTracks.first(where: { $0.id == assetID })?.assetID ?? assetID
        guard let asset = project.assets.first(where: { $0.id == sourceAssetID }),
            asset.raw["kind"] as? String != "image", asset.raw["edithSourceImagePath"] == nil
        else {
            throw Failure(
                "invalid_asset",
                "Select an existing audio or video asset, or an audio track with a valid source, not a still image."
            )
        }
        let source = asset.audioURL
        try requireLocalFile(source)
        try require(
            options.maximumWaveformBins <= 2048 && options.maximumTransients <= 10_000,
            "CLI analysis is bounded to 2048 waveform bins and 10000 transients.")
        var settings = VideoBeatAnalysis.Settings()
        settings.sensitivity = options.sensitivity
        settings.refractorySeconds = options.refractorySeconds
        settings.minimumSpacingSeconds = options.minimumSpacingSeconds
        settings.maximumWaveformBins = options.maximumWaveformBins
        settings.maximumTransients = options.maximumTransients
        do { try settings.validate() } catch {
            throw Failure("invalid_analysis", error.localizedDescription)
        }
        let fps: VideoMarkerFrameRate?
        if let rate { fps = try await markerFrameRate(rate, project: project) } else { fps = nil }
        let analysis = try await VideoBeatAnalysis.analyze(source, settings: settings)
        let document: MarkerDocument?
        if let mapping, let fps {
            try require(
                mapping.sourceInSeconds.isFinite && mapping.sourceOutSeconds.isFinite
                    && mapping.sourceInSeconds >= 0
                    && mapping.sourceOutSeconds > mapping.sourceInSeconds
                    && mapping.sourceOutSeconds <= analysis.duration
                    && mapping.outputStartSeconds.isFinite
                    && mapping.outputStartSeconds >= 0 && mapping.playbackRate.isFinite
                    && (0.05...20).contains(mapping.playbackRate),
                "Invalid source-to-output mapping in seconds.")
            document = MarkerDocument(
                version: 1,
                markers: try analysis.markers(
                    frameRate: fps, sourceRange: mapping.sourceInSeconds..<mapping.sourceOutSeconds,
                    outputStart: mapping.outputStartSeconds, playbackRate: mapping.playbackRate))
        } else {
            document = nil
        }
        return AudioAnalysisReport(
            version: 1, assetID: assetID, sourcePath: source.path,
            samplePositionUnit: "source_samples", sampleRateUnit: "Hz",
            durationSeconds: analysis.duration,
            analysis: analysis, mapping: mapping, frameRate: fps, markerDocument: document)
    }
}
