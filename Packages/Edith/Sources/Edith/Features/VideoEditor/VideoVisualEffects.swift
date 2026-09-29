import CoreImage
import Foundation

struct VideoVisualEffects: Codable, Equatable, Sendable {
    enum Framing: String, Codable, CaseIterable, Sendable { case fit, fill }
    enum Interpolation: String, Codable, CaseIterable, Sendable { case linear, smooth }

    struct Keyframe: Codable, Equatable, Sendable {
        var time: Double
        var scale = 1.0
        var positionX = 0.0
        var positionY = 0.0
        var rotation = 0.0
        var interpolation: Interpolation = .linear

        var isValid: Bool {
            [time, scale, positionX, positionY, rotation].allSatisfy(\.isFinite)
                && time >= 0 && scale > 0 && scale <= 100
                && abs(positionX) <= 100 && abs(positionY) <= 100 && abs(rotation) <= 36000
        }
    }

    var framing: Framing = .fit
    var focalX = 0.5
    var focalY = 0.5
    var exposure = 0.0
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var keyframes: [Keyframe] = []

    var isValid: Bool {
        [focalX, focalY, exposure, brightness, contrast, saturation].allSatisfy(\.isFinite)
            && (0...1).contains(focalX) && (0...1).contains(focalY)
            && (-10...10).contains(exposure) && (-1...1).contains(brightness)
            && (0...4).contains(contrast) && (0...4).contains(saturation)
            && keyframes.allSatisfy(\.isValid)
            && zip(keyframes, keyframes.dropFirst()).allSatisfy { $0.time < $1.time }
    }

    var raw: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
            let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return result
    }

    static func decode(_ raw: Any) throws -> Self {
        guard raw is [String: Any], JSONSerialization.isValidJSONObject(raw) else {
            throw VisualError.invalidEffects
        }
        let data = try JSONSerialization.data(withJSONObject: raw)
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.isValid else { throw VisualError.invalidEffects }
        return result
    }

    func sample(at sourceTime: Double) -> Keyframe {
        guard let first = keyframes.first else { return Keyframe(time: sourceTime) }
        guard sourceTime > first.time else { return first }
        for (left, right) in zip(keyframes, keyframes.dropFirst()) where sourceTime <= right.time {
            let fraction = max(0, min(1, (sourceTime - left.time) / (right.time - left.time)))
            let weight =
                left.interpolation == .smooth ? fraction * fraction * (3 - 2 * fraction) : fraction
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * weight }
            return Keyframe(
                time: sourceTime, scale: mix(left.scale, right.scale),
                positionX: mix(left.positionX, right.positionX),
                positionY: mix(left.positionY, right.positionY),
                rotation: mix(left.rotation, right.rotation))
        }
        return keyframes.last ?? first
    }

    func graded(_ image: CIImage) -> CIImage {
        var output = image
        if exposure != 0 {
            output = output.applyingFilter(
                "CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        }
        if brightness != 0 || contrast != 1 || saturation != 1 {
            output = output.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast,
                    kCIInputSaturationKey: saturation,
                ])
        }
        return output
    }

    func transform(
        source: CGSize, canvas: CGSize, padding: CGFloat, at sourceTime: Double,
        zoom: ZoomAnimation.State = .identity
    ) -> CGAffineTransform {
        let x = canvas.width / source.width
        let y = canvas.height / source.height
        let fit = (framing == .fill ? max(x, y) : min(x, y)) * (1 - 2 * padding)
        let key = sample(at: sourceTime)
        let scale = fit * key.scale * zoom.scale
        let offsetX = (canvas.width - source.width * fit) * focalX
        let offsetY = (canvas.height - source.height * fit) * (1 - focalY)
        let anchorX = source.width * zoom.x
        let anchorY = source.height * (1 - zoom.y)
        return CGAffineTransform(translationX: -anchorX, y: -anchorY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: key.rotation * .pi / 180))
            .concatenating(
                CGAffineTransform(
                    translationX: offsetX + source.width * fit / 2 + key.positionX * canvas.width,
                    y: offsetY + source.height * fit / 2 - key.positionY * canvas.height))
    }

    enum VisualError: LocalizedError {
        case invalidEffects
        case invalidDuration
        var errorDescription: String? {
            switch self {
            case .invalidEffects: "Visual settings contain invalid values or unordered keyframes."
            case .invalidDuration: "Still duration must be a finite positive number."
            }
        }
    }
}

extension VideoProject.Clip {
    var visualEffects: VideoVisualEffects {
        get {
            guard let raw = raw["edithVisualEffects"] else { return VideoVisualEffects() }
            return (try? VideoVisualEffects.decode(raw)) ?? VideoVisualEffects()
        }
        set { if newValue.isValid { raw["edithVisualEffects"] = newValue.raw } }
    }
}

extension VideoProject {
    mutating func setVisualEffects(_ effects: VideoVisualEffects, clipID: String) throws {
        guard effects.isValid else { throw VideoVisualEffects.VisualError.invalidEffects }
        var entries = clips
        guard let index = entries.firstIndex(where: { $0.id == clipID }) else { return }
        entries[index].visualEffects = effects
        setClips(entries)
    }

    mutating func setStillDuration(_ duration: Double, clipID: String) throws {
        guard duration.isFinite, duration > 0, duration < Double(Int64.max) / 600 else {
            throw VideoVisualEffects.VisualError.invalidDuration
        }
        var entries = clips
        guard let index = entries.firstIndex(where: { $0.id == clipID }),
            assets.first(where: { $0.id == entries[index].assetID })?.isStill == true
        else { return }
        let end = entries[index].start + duration
        guard end.isFinite, end < Double(Int64.max) / 600 else {
            throw VideoVisualEffects.VisualError.invalidDuration
        }
        entries[index].end = end
        setClips(entries)
    }
}
