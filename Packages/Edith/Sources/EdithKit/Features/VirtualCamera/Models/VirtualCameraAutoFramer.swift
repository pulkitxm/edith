import CoreGraphics
import Foundation

public struct VirtualCameraAutoFramer: Sendable {
    public struct Shot: Equatable, Sendable {
        public var zoom: Double
        public var centerX: Double
        public var centerY: Double

        public init(zoom: Double, centerX: Double, centerY: Double) {
            self.zoom = zoom
            self.centerX = centerX
            self.centerY = centerY
        }
    }

    public static let maximumZoom = 4.0
    public static let headroom = 0.12

    public var timeConstant: TimeInterval
    public var holdAfterLoss: TimeInterval
    public var deadZone: Double
    public private(set) var current: Shot?
    public private(set) var goal: Shot?
    public private(set) var lastFaceAt: TimeInterval?
    private var lastUpdate: TimeInterval?

    public init(
        timeConstant: TimeInterval = 0.55, holdAfterLoss: TimeInterval = 1.5,
        deadZone: Double = 0.04
    ) {
        self.timeConstant = timeConstant
        self.holdAfterLoss = holdAfterLoss
        self.deadZone = deadZone
    }

    public mutating func reset() {
        current = nil
        goal = nil
        lastFaceAt = nil
        lastUpdate = nil
    }

    public static func shot(
        for faces: [CGRect], mode: VirtualCameraAutoFrame, manual: VirtualCameraFraming,
        source: CGSize, output: CGSize
    ) -> Shot? {
        guard mode != .off, let first = faces.first, source.width > 0, source.height > 0 else {
            return nil
        }
        let union = faces.dropFirst().reduce(first) { $0.union($1) }
        let base = VirtualCameraGeometry.baseCropSize(
            source: source, output: output, tilt: manual.tilt)
        guard base.height > 0 else { return nil }
        let faceHeight = max(union.height * source.height, 1)
        let desiredHeight = faceHeight / mode.faceHeightFraction
        let zoom = min(max(Double(base.height / desiredHeight), 1), maximumZoom)
        var framing = manual
        framing.zoom = zoom
        framing.centerX = Double(union.midX)
        let cropHeight = Double(base.height) / zoom
        framing.centerY = Double(union.midY) + headroom * cropHeight / Double(source.height)
        let clamped = VirtualCameraGeometry.clamped(framing, source: source, output: output)
        return Shot(zoom: clamped.zoom, centerX: clamped.centerX, centerY: clamped.centerY)
    }

    public func isMeaningful(_ candidate: Shot, comparedTo existing: Shot?) -> Bool {
        guard let existing else { return true }
        let span = 1 / max(existing.zoom, 1)
        let moved =
            abs(candidate.centerX - existing.centerX) / span > deadZone
            || abs(candidate.centerY - existing.centerY) / span > deadZone
        let zoomed = abs(log(candidate.zoom / max(existing.zoom, 0.0001))) > deadZone * 1.5
        return moved || zoomed
    }

    public mutating func update(
        faces: [CGRect]?, mode: VirtualCameraAutoFrame, manual: VirtualCameraFraming,
        source: CGSize, output: CGSize, at time: TimeInterval
    ) -> VirtualCameraFraming {
        guard mode != .off else {
            reset()
            return manual
        }
        let manualShot = Shot(zoom: manual.zoom, centerX: manual.centerX, centerY: manual.centerY)
        if let faces {
            if let candidate = Self.shot(
                for: faces, mode: mode, manual: manual, source: source, output: output)
            {
                lastFaceAt = time
                if isMeaningful(candidate, comparedTo: goal) { goal = candidate }
            } else if let lastFaceAt, time - lastFaceAt > holdAfterLoss {
                goal = manualShot
            }
        } else if let lastFaceAt, time - lastFaceAt > holdAfterLoss {
            goal = manualShot
        }
        let target = goal ?? manualShot
        let elapsed = lastUpdate.map { max(time - $0, 0) } ?? 0
        lastUpdate = time
        guard let previous = current else {
            current = target
            return apply(target, to: manual)
        }
        let blend = timeConstant > 0 ? 1 - exp(-elapsed / timeConstant) : 1
        let next = Shot(
            zoom: exp(VirtualCameraMath.mix(log(previous.zoom), log(target.zoom), blend)),
            centerX: VirtualCameraMath.mix(previous.centerX, target.centerX, blend),
            centerY: VirtualCameraMath.mix(previous.centerY, target.centerY, blend))
        current = next
        return apply(next, to: manual)
    }

    private func apply(_ shot: Shot, to manual: VirtualCameraFraming) -> VirtualCameraFraming {
        var framing = manual
        framing.zoom = shot.zoom
        framing.centerX = shot.centerX
        framing.centerY = shot.centerY
        return framing.sanitized()
    }
}
