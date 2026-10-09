import CoreGraphics
import CryptoKit
import Foundation
import Testing

@testable import EdithStudio

enum Corner: String, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}

struct Bitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        bytes = buffer
    }

    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let column = min(max(x, 0), width - 1)
        let row = min(max(y, 0), height - 1)
        let offset = (row * width + column) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    func fraction(
        x: ClosedRange<Double>, y: ClosedRange<Double>,
        where test: ((r: Int, g: Int, b: Int)) -> Bool
    ) -> Double {
        var hits = 0
        var total = 0
        let columns = Int(x.lowerBound * Double(width))..<Int(x.upperBound * Double(width))
        let rows = Int(y.lowerBound * Double(height))..<Int(y.upperBound * Double(height))
        for row in stride(from: rows.lowerBound, to: rows.upperBound, by: 2) {
            for column in stride(from: columns.lowerBound, to: columns.upperBound, by: 2) {
                total += 1
                if test(pixel(column, row)) { hits += 1 }
            }
        }
        return total == 0 ? 0 : Double(hits) / Double(total)
    }

    func bounds(where test: ((r: Int, g: Int, b: Int)) -> Bool) -> CGRect? {
        var minX = Int.max
        var minY = Int.max
        var maxX = -1
        var maxY = -1
        for row in 0..<height {
            for column in 0..<width where test(pixel(column, row)) {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    var redCorner: Corner? {
        let spots: [(Corner, Double, Double)] = [
            (.topLeft, 0.1, 0.1), (.topRight, 0.9, 0.1), (.bottomLeft, 0.1, 0.9),
            (.bottomRight, 0.9, 0.9),
        ]
        let red = spots.filter { spot in
            MediaAudit.isRed(pixel(Int(spot.1 * Double(width)), Int(spot.2 * Double(height))))
        }
        return red.count == 1 ? red[0].0 : nil
    }

    var greenCorner: Corner? {
        let spots: [(Corner, Double, Double)] = [
            (.topLeft, 0.1, 0.1), (.topRight, 0.9, 0.1), (.bottomLeft, 0.1, 0.9),
            (.bottomRight, 0.9, 0.9),
        ]
        let green = spots.filter { spot in
            MediaAudit.isGreen(pixel(Int(spot.1 * Double(width)), Int(spot.2 * Double(height))))
        }
        return green.count == 1 ? green[0].0 : nil
    }

    var centerGray: Int { pixel(width / 2, height / 2).r }

    func span(
        through x: Int, _ y: Int, where test: ((r: Int, g: Int, b: Int)) -> Bool
    ) -> (horizontal: Int, vertical: Int) {
        guard test(pixel(x, y)) else { return (0, 0) }
        var left = x
        var right = x
        var top = y
        var bottom = y
        while left > 0, test(pixel(left - 1, y)) { left -= 1 }
        while right < width - 1, test(pixel(right + 1, y)) { right += 1 }
        while top > 0, test(pixel(x, top - 1)) { top -= 1 }
        while bottom < height - 1, test(pixel(x, bottom + 1)) { bottom += 1 }
        return (right - left + 1, bottom - top + 1)
    }
}

struct AuditProbe {
    let json: [String: Any]

    var info: StudioMediaInfo { FFmpeg.parse(json) }

    var streams: [[String: Any]] { json["streams"] as? [[String: Any]] ?? [] }

    func stream(_ type: String) -> [String: Any]? {
        streams.first { stream in
            let disposition = stream["disposition"] as? [String: Any]
            let attached = (disposition?["attached_pic"] as? Int ?? 0) == 1
            return stream["codec_type"] as? String == type && !attached
        }
    }

    func count(_ type: String) -> Int {
        streams.filter { $0["codec_type"] as? String == type }.count
    }

    func duration(_ type: String) -> Double? {
        FFmpeg.number(stream(type)?["duration"]) ?? info.duration
    }

    var displayWidth: Int? { info.displaySize.map { Int($0.width) } }
    var displayHeight: Int? { info.displaySize.map { Int($0.height) } }

    var bitDepth: Int? {
        guard let audio = stream("audio") else { return nil }
        if let raw = FFmpeg.number(audio["bits_per_raw_sample"]), raw > 0 { return Int(raw) }
        if let bits = FFmpeg.number(audio["bits_per_sample"]), bits > 0 { return Int(bits) }
        return nil
    }
}

enum MediaAudit {
    static var environment: StudioEnvironment { MediaFixtures.environment }
    static let blue = "0x1E40AF"
    static let grayPerSecond = 60.0 * 255 / 219

    static func isRed(_ pixel: (r: Int, g: Int, b: Int)) -> Bool {
        pixel.r > 150 && pixel.g < 100 && pixel.b < 100
    }

    static func isGreen(_ pixel: (r: Int, g: Int, b: Int)) -> Bool {
        pixel.g > 130 && pixel.r < 100 && pixel.b < 100
    }

    static func isWhite(_ pixel: (r: Int, g: Int, b: Int)) -> Bool {
        pixel.r > 200 && pixel.g > 200 && pixel.b > 200
    }

    static func ffmpeg(_ arguments: [String]) async throws {
        try await MediaFixtures.ffmpeg(arguments)
    }

    static func report(_ arguments: [String]) async throws -> String {
        guard let ffmpeg = environment.ffmpeg else { throw StudioError.needsEngine(.ffmpeg) }
        let result = try await StudioProcess.run(
            ffmpeg, ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "info"] + arguments,
            timeout: 120)
        guard result.status == 0 else { throw StudioError.failed(result.errorTail) }
        return result.errorTail
    }

    static func ffprobe(_ arguments: [String]) async throws -> String {
        guard let ffprobe = FFmpeg.ffprobe(in: environment) else {
            throw StudioError.needsEngine(.ffmpeg)
        }
        let result = try await StudioProcess.run(ffprobe, ["-v", "error"] + arguments, timeout: 60)
        guard result.status == 0 else { throw StudioError.failed(result.errorTail) }
        return result.output
    }

    static func probe(_ url: URL) async throws -> AuditProbe {
        let text = try await ffprobe([
            "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return AuditProbe(json: object as? [String: Any] ?? [:])
    }

    static func frameCount(_ url: URL) async throws -> Int {
        let text = try await ffprobe([
            "-count_frames", "-select_streams", "v:0", "-show_entries", "stream=nb_read_frames",
            "-of", "csv=p=0", url.path,
        ])
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    static func frame(_ url: URL, at seconds: Double, in space: Workspace) async throws -> Bitmap {
        let output = space.url("frame-\(UUID().uuidString).png")
        try await ffmpeg([
            "-ss", String(format: "%.3f", seconds), "-i", url.path, "-frames:v", "1", "-update",
            "1", output.path,
        ])
        return Bitmap(try StudioImageIO.load(output))
    }

    static func lastFrame(_ url: URL, in space: Workspace) async throws -> Bitmap {
        let output = space.url("last-\(UUID().uuidString).png")
        try await ffmpeg([
            "-sseof", "-3", "-i", url.path, "-map", "0:v:0", "-update", "1", output.path,
        ])
        return Bitmap(try StudioImageIO.load(output))
    }

    static func image(_ url: URL) throws -> Bitmap {
        Bitmap(try StudioImageIO.load(url))
    }

    static func seconds(of bitmap: Bitmap) -> Double {
        Double(bitmap.centerGray) / grayPerSecond
    }

    static func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func meanVolume(_ url: URL, from start: Double? = nil, to end: Double? = nil)
        async throws -> Double
    {
        var filter = "volumedetect"
        if let start {
            let stop = end.map { ":end=\($0)" } ?? ""
            filter = "atrim=start=\(start)\(stop),asetpts=PTS-STARTPTS," + filter
        }
        let log = try await report([
            "-i", url.path, "-map", "0:a:0", "-af", filter, "-f", "null", "-",
        ])
        return value(after: "mean_volume:", in: log) ?? -200
    }

    static func loudness(_ url: URL) async throws -> Double? {
        let log = try await report([
            "-i", url.path, "-map", "0:a:0", "-af", "ebur128=framelog=quiet", "-f", "null", "-",
        ])
        guard let summary = log.range(of: "Integrated loudness:") else { return nil }
        return value(after: "I:", in: String(log[summary.upperBound...]))
    }

    static func zeroCrossings(_ url: URL) async throws -> Double? {
        let log = try await report([
            "-i", url.path, "-map", "0:a:0", "-af", "pan=mono|c0=c0,astats",
            "-f", "null", "-",
        ])
        return value(after: "Zero crossings rate:", in: log)
    }

    static func silences(_ url: URL, noise: String = "-45dB", minimum: Double = 0.1) async throws
        -> [(start: Double, end: Double)]
    {
        let log = try await report([
            "-i", url.path, "-map", "0:a:0", "-af", "silencedetect=n=\(noise):d=\(minimum)", "-f",
            "null", "-",
        ])
        var starts: [Double] = []
        var result: [(Double, Double)] = []
        for line in log.split(whereSeparator: \.isNewline) {
            if let start = value(after: "silence_start:", in: String(line)) { starts.append(start) }
            if let end = value(after: "silence_end:", in: String(line)) {
                result.append((starts.popLast() ?? 0, end))
            }
        }
        if let open = starts.last { result.append((open, .infinity)) }
        return result
    }

    static func value(after label: String, in text: String) -> Double? {
        guard let range = text.range(of: label, options: .backwards) else { return nil }
        let tail = text[range.upperBound...].drop { $0 == " " }
        let number = tail.prefix { "-+.0123456789".contains($0) }
        return Double(number)
    }

    static func markerSource(width: Int, height: Int, seconds: Double, rate: String) -> String {
        "color=c=\(blue):size=\(width)x\(height):rate=\(rate):duration=\(seconds),"
            + "drawbox=x=0:y=0:w=iw/4:h=ih/4:color=red:t=fill,"
            + "drawbox=x=iw*3/4:y=ih*3/4:w=iw/4:h=ih/4:color=0x00D000:t=fill"
    }

    static let h264 = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
    static let fullChroma = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv444p"]
    static let vp9 = [
        "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-pix_fmt", "yuv420p",
    ]
    static let hevc = [
        "-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-tag:v", "hvc1",
        "-x265-params", "log-level=error",
    ]

    static func video(
        at url: URL, source: String, seconds: Double, audio: String? = "stereo",
        sound: String? = nil, sampleRate: Int = 48000, codec: [String] = h264,
        filter: String? = nil, rotation: Int = 0, shortest: Bool = true, extra: [String] = []
    ) async throws {
        let stored =
            rotation == 0
            ? url
            : url.deletingLastPathComponent().appendingPathComponent(
                "stored-\(UUID().uuidString).\(url.pathExtension)")
        var arguments = ["-f", "lavfi", "-i", source]
        if audio != nil {
            let tone = "sine=frequency=440:sample_rate=\(sampleRate):duration=\(seconds)"
            arguments += ["-f", "lavfi", "-i", sound ?? tone]
        }
        var filters: [String] = []
        if let filter { filters.append(filter) }
        switch rotation {
        case 90: filters.append("transpose=clock")
        case 270: filters.append("transpose=cclock")
        case 180: filters.append("hflip,vflip")
        default: break
        }
        if !filters.isEmpty { arguments += ["-vf", filters.joined(separator: ",")] }
        arguments += codec
        if let audio {
            let channels = ["mono": "1", "stereo": "2", "5.1": "6"][audio] ?? "2"
            let audioCodec =
                url.pathExtension == "webm"
                ? ["-c:a", "libopus"] : ["-c:a", "aac", "-b:a", "128k"]
            arguments += ["-ac", channels] + audioCodec + (shortest ? ["-shortest"] : [])
        }
        try await ffmpeg(arguments + extra + [stored.path])
        if rotation != 0 {
            try await ffmpeg([
                "-display_rotation:v", String(rotation), "-i", stored.path, "-c", "copy",
                url.path,
            ])
            try? FileManager.default.removeItem(at: stored)
        }
    }

    static func marker(
        at url: URL, width: Int = 320, height: Int = 240, seconds: Double = 1,
        rate: String = "25", audio: String? = "stereo", sampleRate: Int = 48000,
        codec: [String] = h264, rotation: Int = 0
    ) async throws {
        try await video(
            at: url,
            source: markerSource(width: width, height: height, seconds: seconds, rate: rate),
            seconds: seconds, audio: audio, sampleRate: sampleRate, codec: codec,
            rotation: rotation)
    }

    static func plain(
        at url: URL, width: Int = 320, height: Int = 180, seconds: Double = 1, rotation: Int = 0,
        audio: String? = "stereo"
    ) async throws {
        try await video(
            at: url,
            source: "color=c=\(blue):size=\(width)x\(height):rate=25:duration=\(seconds)",
            seconds: seconds, audio: audio, rotation: rotation)
    }

    static let lossless = [
        "-c:v", "libx264", "-qp", "0", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
    ]

    static func ramp(
        at url: URL, seconds: Double = 3, rate: String = "25", audio: String? = "stereo",
        sound: String? = nil, variable: Bool = false
    ) async throws {
        let source =
            "color=c=black:size=64x48:rate=\(rate):duration=\(seconds),format=yuv420p,"
            + "geq=lum='16+T*60':cb=128:cr=128"
        try await video(
            at: url, source: source, seconds: seconds, audio: audio, sound: sound,
            codec: lossless, filter: variable ? "select='lt(t,1)+not(mod(n,3))'" : nil,
            extra: variable ? ["-fps_mode", "vfr"] : [])
    }

    static func sound(
        at url: URL, expression: String, seconds: Double, sampleRate: Int = 48000,
        channels: Int = 2, codec: [String] = []
    ) async throws {
        try await ffmpeg(
            [
                "-f", "lavfi", "-i", "aevalsrc='\(expression)':s=\(sampleRate):d=\(seconds)",
                "-ac", String(channels),
            ] + codec + [url.path])
    }

    static func tone(
        at url: URL, seconds: Double, frequency: Int = 440, amplitude: Double = 0.5,
        sampleRate: Int = 48000, channels: Int = 2, codec: [String] = []
    ) async throws {
        try await sound(
            at: url, expression: "\(amplitude)*sin(2*PI*\(frequency)*t)", seconds: seconds,
            sampleRate: sampleRate, channels: channels, codec: codec)
    }

    static func solidPNG(
        at url: URL, width: Int, height: Int, red: Double, green: Double, blue: Double
    )
        throws
    {
        let context = try MediaGraphics.canvas(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try MediaGraphics.writePNG(context, to: url)
    }

    static func outputs(_ space: Workspace) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: space.output, includingPropertiesForKeys: nil)) ?? []
    }

    static func bare(_ space: Workspace) -> StudioEnvironment {
        var environment = StudioEnvironment()
        environment.temporaryRoot = space.url("bare-staging")
        return environment
    }
}

extension Workspace {
    func audit(
        _ id: String, _ inputs: [URL], _ values: [String: StudioValue] = [:],
        environment: StudioEnvironment? = nil
    ) async throws -> StudioRunResult {
        let before = inputs.map(MediaAudit.digest)
        defer {
            let after = inputs.map(MediaAudit.digest)
            #expect(after == before, "\(id) changed its input")
        }
        return try await run(id, inputs, values, environment: environment)
    }

    func auditURL(
        _ id: String, _ inputs: [URL], _ values: [String: StudioValue] = [:]
    ) async throws -> URL {
        try await audit(id, inputs, values).url()
    }
}
