import AVFoundation
import CoreImage
import Metal

public struct VideoSettings: Codable, Equatable, Sendable {
    public enum ColorSpace: String, Codable, CaseIterable, Sendable {
        case rec709
        case displayP3

        var cgColorSpace: CGColorSpace {
            CGColorSpace(name: self == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.itur_709)!
        }
    }

    public var width: Int
    public var height: Int
    public var frameRateNumerator: Int
    public var frameRateDenominator: Int
    public var colorSpace: ColorSpace

    public init(
        width: Int = 1920, height: Int = 1080, frameRateNumerator: Int = 60,
        frameRateDenominator: Int = 1, colorSpace: ColorSpace = .rec709
    ) {
        self.width = width
        self.height = height
        self.frameRateNumerator = frameRateNumerator
        self.frameRateDenominator = frameRateDenominator
        self.colorSpace = colorSpace
    }

    var size: CGSize { CGSize(width: width, height: height) }
    var frameRate: Double { Double(frameRateNumerator) / Double(frameRateDenominator) }
    var frameDuration: CMTime {
        guard isValid else { return .invalid }
        return CMTime(value: Int64(frameRateDenominator), timescale: Int32(frameRateNumerator))
    }
    var isValid: Bool {
        (2...16384).contains(width) && (2...16384).contains(height)
            && width.isMultiple(of: 2) && height.isMultiple(of: 2)
            && (1...Int(Int32.max)).contains(frameRateNumerator)
            && (1...Int(Int32.max)).contains(frameRateDenominator)
            && (1...240).contains(frameRate)
    }
    var raw: [String: Any] {
        [
            "width": width, "height": height,
            "frameRateNumerator": frameRateNumerator,
            "frameRateDenominator": frameRateDenominator, "colorSpace": colorSpace.rawValue,
        ]
    }

    static func decode(_ raw: [String: Any]) throws -> Self {
        guard let width = raw["width"] as? Int, let height = raw["height"] as? Int,
            let numerator = raw["frameRateNumerator"] as? Int,
            let denominator = raw["frameRateDenominator"] as? Int,
            let name = raw["colorSpace"] as? String, let color = ColorSpace(rawValue: name)
        else { throw ValidationError.invalidSettings }
        let result = Self(
            width: width, height: height, frameRateNumerator: numerator,
            frameRateDenominator: denominator, colorSpace: color)
        guard result.isValid else { throw ValidationError.invalidSettings }
        return result
    }

    enum ValidationError: LocalizedError {
        case invalidSettings
        var errorDescription: String? {
            "Use even canvas dimensions from 2 to 16384 and a positive rational frame rate from 1 to 240 fps."
        }
    }
}

extension VideoProject {
    var videoSettings: VideoSettings {
        get {
            guard let raw = root["edithVideoSettings"] as? [String: Any] else {
                return VideoSettings()
            }
            return (try? VideoSettings.decode(raw)) ?? VideoSettings()
        }
        set {
            guard newValue.isValid else { return }
            root["edithVideoSettings"] = newValue.raw
        }
    }

    var frameDuration: CMTime { videoSettings.frameDuration }

    mutating func setCanvasAspectRatio(_ ratio: String) throws {
        var settings = videoSettings
        if ratio == "native" {
            if let clip = clips.first, let asset = assets.first(where: { $0.id == clip.assetID }) {
                guard let metadata = asset.raw["video"] as? [String: Any],
                    let width = metadata["width"] as? Int, let height = metadata["height"] as? Int,
                    (1...16384).contains(width), (1...16384).contains(height)
                else { throw VideoSettings.ValidationError.invalidSettings }
                settings.width = max(2, width / 2 * 2)
                settings.height = max(2, height / 2 * 2)
            }
        } else {
            let parts = ratio.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw VideoSettings.ValidationError.invalidSettings
            }
            let longest = Double(max(settings.width, settings.height))
            let factor = longest / max(parts[0], parts[1])
            settings.width = max(2, Int((parts[0] * factor / 2).rounded()) * 2)
            settings.height = max(2, Int((parts[1] * factor / 2).rounded()) * 2)
        }
        guard settings.isValid else { throw VideoSettings.ValidationError.invalidSettings }
        videoSettings = settings
        aspectRatio = ratio
    }

    func validateVideoSettings() throws {
        if let raw = root["edithVideoSettings"] {
            guard let dictionary = raw as? [String: Any] else {
                throw VideoSettings.ValidationError.invalidSettings
            }
            _ = try VideoSettings.decode(dictionary)
        }
    }
}

enum VideoImageContext {
    static let shared = make()
    private static let rec709 = make(output: VideoSettings.ColorSpace.rec709.cgColorSpace)
    private static let displayP3 = make(output: VideoSettings.ColorSpace.displayP3.cgColorSpace)

    static func context(for colorSpace: VideoSettings.ColorSpace) -> CIContext {
        colorSpace == .displayP3 ? displayP3 : rec709
    }

    private static func make(output: CGColorSpace? = nil) -> CIContext {
        var options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: false,
        ]
        if let output { options[.outputColorSpace] = output }
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(
            options: options.merging([.useSoftwareRenderer: true]) { _, value in value })
    }
}
