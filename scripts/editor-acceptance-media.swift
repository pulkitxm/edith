import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import ImageIO

struct AcceptanceError: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw AcceptanceError(description: message) }
}

func checksum(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

func json(_ value: Any, to url: URL? = nil) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    if let url { try data.write(to: url) } else { print(String(decoding: data, as: UTF8.self)) }
}

func shotImage(_ number: Int) -> CIImage {
    let bounds = CGRect(x: 0, y: 0, width: 180, height: 320)
    var image = CIImage(color: CIColor(
        red: Double(number % 5 + 1) / 6,
        green: Double(number / 5 % 3 + 1) / 4,
        blue: Double(number / 15 + 1) / 4)).cropped(to: bounds)
    for bit in 0..<6 {
        let value = (number + 1) & (1 << bit) == 0 ? 0.05 : 0.95
        let bar = CIImage(color: CIColor(red: value, green: value, blue: value))
            .cropped(to: CGRect(x: 12 + bit * 26, y: 128, width: 20, height: 64))
        image = bar.composited(over: image)
    }
    return image
}

func movie(_ image: CIImage, to url: URL, context: CIContext) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 180, AVVideoHeightKey: 320,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 500_000],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 180,
            kCVPixelBufferHeightKey as String: 320,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
    writer.add(input)
    try require(writer.startWriting(), "Could not start fixture writer")
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<60 {
        while !input.isReadyForMoreMediaData {
            try require(writer.status == .writing, "Fixture writer failed")
            try await Task.sleep(for: .milliseconds(2))
        }
        var buffer: CVPixelBuffer?
        try require(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess,
            "Could not allocate fixture frame")
        context.render(image, to: buffer!)
        try require(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 60)),
            "Could not append fixture frame")
    }
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
    input.markAsFinished()
    await writer.finishWriting()
    try require(writer.status == .completed, "Could not finish fixture movie")
}

func generate(_ directory: URL) async throws {
    try require(!FileManager.default.fileExists(atPath: directory.path), "Fixture directory must not exist")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let context = CIContext()
    var shots: [[String: Any]] = []
    for index in 0..<45 {
        let name = String(format: "shot-%02d", index + 1)
        let image = shotImage(index)
        let png = directory.appendingPathComponent(name + ".png")
        let video = directory.appendingPathComponent(name + ".mov")
        try context.writePNGRepresentation(of: image, to: png, format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        try await movie(image, to: video, context: context)
        shots.append([
            "name": name, "video": video.lastPathComponent, "still": png.lastPathComponent,
            "frames": index < 18 ? 39 : 38,
            "videoSHA256": try checksum(video), "stillSHA256": try checksum(png),
        ])
    }
    let audio = directory.appendingPathComponent("music.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_382_400)!
    buffer.frameLength = buffer.frameCapacity
    for index in 0..<Int(buffer.frameLength) {
        buffer.floatChannelData![0][index] = Float(sin(2 * .pi * 440 * Double(index) / 48_000)) * 0.2
    }
    try AVAudioFile(forWriting: audio, settings: format.settings).write(from: buffer)
    try json([
        "version": 1, "shots": shots, "fps": 60, "frames": 1728, "duration": 28.8,
        "width": 1080, "height": 1920, "music": "music.wav",
        "musicSHA256": try checksum(audio),
    ], to: directory.appendingPathComponent("manifest.json"))
    try json(["fixture": "synthetic", "shots": 45, "frames": 1728, "duration": 28.8])
}

func identity(_ buffer: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    var result = 0
    for bit in 0..<6 {
        let x = (22 + bit * 26) * width / 180
        let offset = height / 2 * stride + x * 4
        if Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2]) > 384 {
            result |= 1 << bit
        }
    }
    return result
}

func verifyFixture(_ directory: URL) async throws {
    let context = CIContext()
    var hashes = Set<String>()
    for number in 1...45 {
        let url = directory.appendingPathComponent(String(format: "shot-%02d.mov", number))
        hashes.insert(try checksum(url))
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        try require(abs(duration - 1) < 0.0001, "Fixture shot duration is incorrect")
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try await generator.image(at: .zero).image
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        context.render(CIImage(cgImage: image), to: buffer!)
        try require(identity(buffer!) == number, "Fixture identity is incorrect")
    }
    try require(hashes.count == 45, "Fixture sources are not unique")
    let audio = try AVAudioFile(forReading: directory.appendingPathComponent("music.wav"))
    try require(audio.length == 1_382_400 && audio.fileFormat.sampleRate == 48_000,
        "Fixture music duration is incorrect")
    try json(["fixtureVerified": true, "distinctSources": hashes.count, "musicSamples": audio.length])
}

func inspect(_ url: URL, exact: Bool, preview: URL?) async throws {
    let asset = AVURLAsset(url: url)
    let video = try await asset.loadTracks(withMediaType: .video)
    try require(video.count == 1, "Expected one video stream")
    let track = video[0]
    let size = try await track.load(.naturalSize)
    let fps = try await track.load(.nominalFrameRate)
    let duration = try await asset.load(.duration).seconds
    let descriptions = try await track.load(.formatDescriptions)
    let codec = CMFormatDescriptionGetMediaSubType(descriptions[0])
    try require(codec == kCMVideoCodecType_H264, "Expected H.264 video")
    try require(abs(duration - 28.8) <= 1.0 / 60, "Expected 28.8-second output, got \(duration)")
    if exact {
        try require(size == CGSize(width: 1080, height: 1920), "Expected 1080x1920, got \(size)")
        try require(abs(fps - 60) < 0.001, "Expected 60 fps, got \(fps)")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    try require(reader.startReading(), "Could not decode video")
    var frames = 0
    var identities = Set<Int>()
    var previousTime = -1.0
    while let sample = output.copyNextSampleBuffer() {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        try require(time > previousTime, "Video timestamps must increase")
        previousTime = time
        let number = identity(CMSampleBufferGetImageBuffer(sample)!)
        identities.insert(number)
        if exact {
            try require(abs(time - Double(frames) / 60) < 0.0001, "Frame timestamp mismatch at \(frames)")
            let expected = frames < 702 ? frames / 39 + 1 : (frames - 702) / 38 + 19
            try require(number == expected, "Shot identity mismatch at frame \(frames): \(number), expected \(expected)")
        }
        frames += 1
    }
    try require(reader.status == .completed, "Video decode failed")
    try require(identities == Set(1...45), "Expected 45 distinct decoded shot identities")
    if exact { try require(frames == 1728, "Expected 1728 decoded frames, got \(frames)") }
    let audio = try await asset.loadTracks(withMediaType: .audio)
    try require(audio.count == 1, "Expected one continuous music stream")
    let audioDescriptions = try await audio[0].load(.formatDescriptions)
    try require(CMFormatDescriptionGetMediaSubType(audioDescriptions[0]) == kAudioFormatMPEG4AAC,
        "Expected AAC music")
    let audioReader = try AVAssetReader(asset: asset)
    let audioOutput = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
    ])
    audioReader.add(audioOutput)
    try require(audioReader.startReading(), "Could not decode music")
    var samples: [Float] = []
    while let sample = audioOutput.copyNextSampleBuffer() {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        try require(abs(time - Double(samples.count) / 48_000) < 2.0 / 48_000,
            "Music has a timestamp gap at \(time)")
        let block = CMSampleBufferGetDataBuffer(sample)!
        let length = CMBlockBufferGetDataLength(block)
        var chunk = [Float](repeating: 0, count: length / 4)
        let status = chunk.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        try require(status == kCMBlockBufferNoErr, "Could not read music samples")
        samples.append(contentsOf: chunk)
    }
    try require(audioReader.status == .completed, "Music decode failed")
    try require(abs(Double(samples.count) / 48_000 - 28.8) < 0.025, "Music does not span the full edit")
    var minimumRMS = Double.infinity
    var maximumFrequencyError = 0.0
    for start in stride(from: 0, to: min(samples.count, 1_382_400) - 480, by: 480) {
        let window = samples[start..<(start + 480)]
        let rms = sqrt(window.reduce(0.0) { $0 + Double($1 * $1) } / 480)
        minimumRMS = min(minimumRMS, rms)
        try require(rms > 0.08 && rms < 0.22, "Music dropout or level error at sample \(start)")
        let crossings = zip(window, window.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        maximumFrequencyError = max(maximumFrequencyError, abs(Double(crossings) * 100 - 440))
    }
    try require(maximumFrequencyError <= 160, "Generated tone frequency changed")
    if let preview {
        guard let source = CGImageSourceCreateWithURL(preview as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw AcceptanceError(description: "Preview is not a decodable image") }
        try require(CGImageSourceGetType(source) as String? == "public.png", "Preview must be PNG")
        try require(image.width == Int(size.width) && image.height == Int(size.height),
            "Preview and export dimensions differ")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let rendered = try await generator.image(at: CMTime(value: 15, timescale: 60)).image
        let context = CIContext()
        func pixels(_ image: CGImage) -> [UInt8] {
            let small = CIImage(cgImage: image).transformed(by:
                CGAffineTransform(scaleX: 18.0 / Double(image.width), y: 32.0 / Double(image.height)))
            var values = [UInt8](repeating: 0, count: 18 * 32 * 4)
            context.render(small, toBitmap: &values, rowBytes: 18 * 4,
                bounds: CGRect(x: 0, y: 0, width: 18, height: 32), format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
            return values
        }
        let differences = zip(pixels(image), pixels(rendered)).map { abs(Int($0) - Int($1)) }
        try require(Double(differences.reduce(0, +)) / Double(differences.count) < 8,
            "Preview does not match the rendered output")
    }
    try json([
        "mode": exact ? "delivery" : "baseline", "codec": "h264", "audioCodec": "aac",
        "width": Int(size.width), "height": Int(size.height), "fps": fps,
        "frames": frames, "duration": duration, "distinctShots": identities.count,
        "audioSamples": samples.count, "minimumMusicRMS": minimumRMS,
        "sha256": try checksum(url),
    ])
}

@main struct EditorAcceptanceMedia {
    static func main() async throws {
        let arguments = CommandLine.arguments
        try require(arguments.count >= 3, "Usage: editor-acceptance-media generate|inspect|baseline PATH")
        let url = URL(fileURLWithPath: arguments[2])
        switch arguments[1] {
        case "generate": try await generate(url)
        case "verify-fixture": try await verifyFixture(url)
        case "inspect", "baseline":
            let preview = arguments.count > 3 ? URL(fileURLWithPath: arguments[3]) : nil
            try await inspect(url, exact: arguments[1] == "inspect", preview: preview)
        default: throw AcceptanceError(description: "Unknown command")
        }
    }
}
