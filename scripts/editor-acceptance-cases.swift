import AVFoundation
import CoreImage
import Foundation
import ImageIO

func detailImage() -> CIImage {
    let bounds = CGRect(x: 0, y: 0, width: 3840, height: 2160)
    let field = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.7)).cropped(to: bounds)
    let detail = CIFilter(name: "CICheckerboardGenerator", parameters: [
        "inputCenter": CIVector(x: 0, y: 0), "inputWidth": 2, "inputSharpness": 1,
        "inputColor0": CIColor.black, "inputColor1": CIColor.white,
    ])!.outputImage!.cropped(to: CGRect(x: 1792, y: 952, width: 256, height: 256))
    return detail.composited(over: field)
}

func tone(_ url: URL, samples: Int, resetAt: Int? = nil) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples))!
    buffer.frameLength = buffer.frameCapacity
    for index in 0..<samples {
        let position = resetAt.map { index >= $0 ? index - $0 : index } ?? index
        buffer.floatChannelData![0][index] = Float(sin(2 * .pi * 440 * Double(position) / 48_000)) * 0.2
    }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
}

func generateExtended(_ directory: URL) async throws {
    try require(!FileManager.default.fileExists(atPath: directory.path), "Fixture directory must not exist")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let context = CIContext()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let original = directory.appendingPathComponent("original-detail.png")
    try context.writePNGRepresentation(of: detailImage(), to: original, format: .RGBA8, colorSpace: colorSpace)
    let proxy = directory.appendingPathComponent("proxy-detail.png")
    let reduced = detailImage().applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 0.125])
    try context.writePNGRepresentation(of: reduced, to: proxy, format: .RGBA8, colorSpace: colorSpace)
    let degraded = reduced.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 8.0])
    try context.writePNGRepresentation(of: degraded, to: directory.appendingPathComponent("proxy-upscaled.png"),
        format: .RGBA8, colorSpace: colorSpace)
    for (name, numerator, denominator) in [("cadence-120", 120, 1), ("cadence-60000-1001", 60000, 1001)] {
        try await movie(shotImage(0), to: directory.appendingPathComponent(name + ".mov"), context: context,
            frameCount: 240, step: CMTime(value: Int64(denominator), timescale: Int32(numerator)),
            imageAtFrame: { shotImage($0 % 45) })
    }
    try tone(directory.appendingPathComponent("music-45-cuts.wav"), samples: 1_382_400)
    try tone(directory.appendingPathComponent("music-variable-speed.wav"), samples: 216_000)
    try tone(directory.appendingPathComponent("music-phase-reset.wav"), samples: 216_000, resetAt: 100_000)
    try tone(directory.appendingPathComponent("music-truncated.wav"), samples: 215_840)
    let audio = AVURLAsset(url: directory.appendingPathComponent("music-variable-speed.wav"))
    let encoder = AVAssetExportSession(asset: audio, presetName: AVAssetExportPresetAppleM4A)!
    try await encoder.export(to: directory.appendingPathComponent("music-aac-control.m4a"), as: .m4a)
    let sourceFolder = directory.appendingPathComponent("collection-sources")
    try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    var groups: [[[String: Any]]] = Array(repeating: [], count: 6)
    for index in 0..<270 {
        let name = String(format: "source-%03d", index + 1)
        let image = shotImage(index % 45).composited(over:
            CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 180, height: 320)))
        let stripe = CIImage(color: CIColor(red: Double(index / 45 + 1) / 7, green: 0.15, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 16, width: 180, height: 48))
        let identified = stripe.composited(over: image)
        let url = sourceFolder.appendingPathComponent(name + ".png")
        try context.writePNGRepresentation(of: identified, to: url, format: .RGBA8, colorSpace: colorSpace)
        groups[index / 45].append(["path": "collection-sources/" + url.lastPathComponent,
            "sourceIdentity": name, "sha256": try checksum(url)])
        if index == 1 {
            try context.writeJPEGRepresentation(of: identified,
                to: sourceFolder.appendingPathComponent("alternate-export-002.jpg"), colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
        }
    }
    try FileManager.default.copyItem(at: sourceFolder.appendingPathComponent("source-001.png"),
        to: sourceFolder.appendingPathComponent("renamed-duplicate-001.png"))
    var frame = 0
    let markerFrames = (0..<45).map { index -> Int in
        defer { frame += index < 18 ? 39 : 38 }
        return frame
    }
    try json([
        "version": 1, "originalStill": "original-detail.png", "originalStillSHA256": try checksum(original),
        "proxyStill": "proxy-detail.png", "proxyStillSHA256": try checksum(proxy),
        "markerFrames": markerFrames, "markerFPSNumerator": 60, "markerFPSDenominator": 1,
        "variableSpeedRates": [0.5, 1.0, 2.0, 1.0], "variableSpeedOutputFrames": 270,
        "variableSpeedMusicSamples": 216_000, "collectionProjects": groups,
        "identityAliases": [
            ["path": "collection-sources/renamed-duplicate-001.png", "sourceIdentity": "source-001"],
            ["path": "collection-sources/alternate-export-002.jpg", "sourceIdentity": "source-002"],
        ],
    ], to: directory.appendingPathComponent("extended-manifest.json"))
    try json(["extendedFixtureGenerated": true, "collectionProjects": 6, "distinctSources": 270])
}

func verifyOriginalDetail(_ url: URL, emit: Bool = true) throws {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw AcceptanceError(description: "Original-detail output is not a decodable image") }
    try require(image.width == 3840 && image.height == 2160, "Original-detail output must be 3840x2160")
    let context = CIContext()
    let bounds = CGRect(x: 1792, y: 952, width: 256, height: 256)
    func values(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
        context.render(image, toBitmap: &bytes, rowBytes: 256 * 4, bounds: bounds,
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return bytes
    }
    let expected = values(detailImage())
    let actual = values(CIImage(cgImage: image))
    let error = zip(expected, actual).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(actual.count)
    try require(error < 8, "Original 2-pixel detail was lost, mean error \(error)")
    if emit { try json(["originalDetailVerified": true, "meanPixelError": error, "width": 3840, "height": 2160]) }
}

func verifyCadence(_ url: URL, frames: Int, numerator: Int32, denominator: Int64, emit: Bool = true) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw AcceptanceError(description: "Cadence output has no video")
    }
    let step = CMTime(value: denominator, timescale: numerator)
    let expectedDuration = CMTimeMultiply(step, multiplier: Int32(frames))
    let range = try await track.load(.timeRange)
    try require(CMTimeCompare(range.start, .zero) == 0 && CMTimeCompare(range.duration, expectedDuration) == 0,
        "Cadence track duration must preserve the exact rational frame grid: got \(range), expected \(expectedDuration)")
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    try require(reader.startReading(), "Could not read cadence output")
    var count = 0
    while let sample = output.copyNextSampleBuffer() {
        let expected = CMTimeMultiply(step, multiplier: Int32(count))
        try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), expected) == 0,
            "Cadence timestamp mismatch at frame \(count)")
        try require(identity(CMSampleBufferGetImageBuffer(sample)!) == count % 45 + 1,
            "Repeated, dropped, or reordered cadence frame at \(count)")
        count += 1
    }
    try require(reader.status == .completed && count == frames, "Cadence frame count mismatch")
    if emit { try json(["cadenceVerified": true, "frames": count, "fpsNumerator": numerator, "fpsDenominator": denominator]) }
}

func verifyMusic(_ url: URL, expectedSamples: Int, sourceOffset: Int = 0, emit: Bool = true) async throws {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    try require(tracks.count == 1, "Expected exactly one rendered music stream")
    let track = tracks[0]
    let descriptions = try await track.load(.formatDescriptions)
    let format = CMAudioFormatDescriptionGetStreamBasicDescription(descriptions[0])!.pointee
    let rate = format.mSampleRate
    let channels = Int(format.mChannelsPerFrame)
    try require(rate == 48_000, "Rendered music must retain 48 kHz")
    try require((1...2).contains(channels), "Expected mono or stereo fixture music")
    let range = try await track.load(.timeRange)
    let end = Double(expectedSamples) / 48_000
    try require(abs(range.start.seconds) < 1.0 / 48_000 && abs(range.duration.seconds - end) < 1.0 / 48_000,
        "Music stream must cover exactly zero through \(expectedSamples) samples; container priming must be trimmed")
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    try require(reader.startReading(), "Could not decode continuous music")
    var samples: [Float] = []
    while let sample = output.copyNextSampleBuffer() {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        try require(abs(time * 48_000 - Double(samples.count / channels)) < 0.51, "Music contains a sample gap or overlap")
        let block = CMSampleBufferGetDataBuffer(sample)!
        let length = CMBlockBufferGetDataLength(block)
        var chunk = [Float](repeating: 0, count: length / 4)
        let status = chunk.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        try require(status == kCMBlockBufferNoErr, "Could not read continuous music samples")
        samples.append(contentsOf: chunk)
    }
    try require(reader.status == .completed && samples.count == expectedSamples * channels,
        "Expected exactly \(expectedSamples) decoded music frames, got \(samples.count / channels)")
    var maximumRMSError = 0.0
    var maximumStep = 0.0
    for start in stride(from: 0, to: expectedSamples, by: 480) {
        let stop = min(start + 480, expectedSamples)
        var error = 0.0
        for index in start..<stop {
            let expected = sin(2 * .pi * 440 * Double(index + sourceOffset) / 48_000) * 0.2
            for channel in 0..<channels {
                let position = index * channels + channel
                error += pow(Double(samples[position]) - expected, 2)
                if index > 0 { maximumStep = max(maximumStep, Double(abs(samples[position] - samples[position - channels]))) }
            }
        }
        let rms = sqrt(error / Double((stop - start) * channels))
        maximumRMSError = max(maximumRMSError, rms)
        try require(rms < 0.025, "Music phase, frequency, or level changed in sample window \(start)..<\(stop)")
    }
    try require(maximumStep < 0.045, "Music contains an abrupt sample step of \(maximumStep)")
    if emit { try json(["continuousMusicVerified": true, "samples": expectedSamples, "channels": channels,
        "maximumWindowRMSError": maximumRMSError, "maximumSampleStep": maximumStep, "sampleRate": rate,
        "sourceOffsetSamples": sourceOffset]) }
}

func verifyRange(_ url: URL, start: Int, end: Int, codec: String, color: String) async throws {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    try require(tracks.count == 1, "Expected one range video stream")
    let track = tracks[0]
    let size = try await track.load(.naturalSize)
    try require(size == CGSize(width: 1080, height: 1920), "Range delivery changed portrait dimensions")
    let descriptions = try await track.load(.formatDescriptions)
    let expectedCodec = codec == "proRes422HQ" ? kCMVideoCodecType_AppleProRes422HQ : kCMVideoCodecType_H264
    try require(CMFormatDescriptionGetMediaSubType(descriptions[0]) == expectedCodec, "Range video codec mismatch")
    let extensions = CMFormatDescriptionGetExtensions(descriptions[0]).map { $0 as NSDictionary } ?? NSDictionary()
    let primaries = color == "displayP3" ? AVVideoColorPrimaries_P3_D65 : AVVideoColorPrimaries_ITU_R_709_2
    let transfer = color == "displayP3" ? kCVImageBufferTransferFunction_sRGB as String : AVVideoTransferFunction_ITU_R_709_2
    try require(extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String == primaries
        && extensions[kCMFormatDescriptionExtension_TransferFunction] as? String == transfer,
        "Range video color tags mismatch")
    let duration = try await asset.load(.duration)
    try require(CMTimeCompare(duration, CMTime(value: Int64(end - start), timescale: 60)) == 0,
        "Range duration is not the exact half-open selection")
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    try require(reader.startReading(), "Could not decode range output")
    var count = 0
    while let sample = output.copyNextSampleBuffer() {
        try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),
            CMTime(value: Int64(count), timescale: 60)) == 0, "Range timestamps must start at zero on the exact frame grid")
        let original = start + count
        let expected = original < 702 ? original / 39 + 1 : (original - 702) / 38 + 19
        try require(identity(CMSampleBufferGetImageBuffer(sample)!) == expected, "Range sampled the wrong original timeline frame")
        count += 1
    }
    try require(reader.status == .completed && count == end - start, "Range frame count mismatch")
    let audio = try await asset.loadTracks(withMediaType: .audio)
    try require(audio.count == 1, "Range music stream is missing")
    let audioDescriptions = try await audio[0].load(.formatDescriptions)
    let expectedAudio = codec == "proRes422HQ" ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC
    try require(CMFormatDescriptionGetMediaSubType(audioDescriptions[0]) == expectedAudio, "Range audio codec mismatch")
    try await verifyMusic(url, expectedSamples: (end - start) * 800, sourceOffset: start * 800, emit: false)
    try json(["rangeVerified": true, "frames": count, "startFrame": start, "endFrame": end,
        "codec": codec, "colorSpace": color, "timestampsRebasedToZero": true, "originalMusicPhasePreserved": true,
        "sha256": try checksum(url)])
}

func verifyExtended(_ directory: URL) async throws {
    try verifyOriginalDetail(directory.appendingPathComponent("original-detail.png"), emit: false)
    do {
        try verifyOriginalDetail(directory.appendingPathComponent("proxy-upscaled.png"), emit: false)
        throw AcceptanceError(description: "Proxy negative control unexpectedly retained original detail")
    } catch let error as AcceptanceError {
        try require(error.description.hasPrefix("Original 2-pixel detail was lost"), error.description)
    }
    try await verifyCadence(directory.appendingPathComponent("cadence-120.mov"),
        frames: 240, numerator: 120, denominator: 1, emit: false)
    try await verifyCadence(directory.appendingPathComponent("cadence-60000-1001.mov"),
        frames: 240, numerator: 60000, denominator: 1001, emit: false)
    try await verifyMusic(directory.appendingPathComponent("music-45-cuts.wav"), expectedSamples: 1_382_400, emit: false)
    try await verifyMusic(directory.appendingPathComponent("music-variable-speed.wav"), expectedSamples: 216_000, emit: false)
    try await verifyMusic(directory.appendingPathComponent("music-aac-control.m4a"), expectedSamples: 216_000, emit: false)
    for (name, message) in [("music-phase-reset.wav", "Music phase, frequency, or level changed"),
        ("music-truncated.wav", "Music stream must cover exactly")] {
        do {
            try await verifyMusic(directory.appendingPathComponent(name), expectedSamples: 216_000, emit: false)
            throw AcceptanceError(description: "Music negative control unexpectedly passed: \(name)")
        } catch let error as AcceptanceError {
            try require(error.description.hasPrefix(message), error.description)
        }
    }
    try json(["extendedFixtureVerified": true, "originalDetail": true, "proxyNegativeControl": true,
        "fps120": true, "fps60000Over1001": true, "music45Cuts": true, "musicVariableSpeed": true,
        "aacPositiveControl": true, "musicPhaseResetRejected": true, "musicTruncationRejected": true])
}
