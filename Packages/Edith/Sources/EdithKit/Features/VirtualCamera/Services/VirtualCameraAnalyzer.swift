import CoreGraphics
import CoreImage
import Foundation
import Vision

public final class VirtualCameraAnalyzer: @unchecked Sendable {
    public struct Snapshot {
        public var faces: [CGRect]?
        public var mask: CIImage?
    }

    public static let analysisWidth: CGFloat = 512

    private let queue = DispatchQueue(label: "com.pulkit.edith.camera.vision", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var mask: CIImage?
    private var faces: [CGRect]?
    private var generation = 0
    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let faceRequest = VNDetectFaceRectanglesRequest()

    public init() {}

    public func submit(_ image: CIImage, wantsMask: Bool, wantsFaces: Bool) {
        guard wantsMask || wantsFaces else {
            reset()
            return
        }
        let generation = lock.withLock { () -> Int? in
            guard !busy else { return nil }
            busy = true
            if !wantsMask { mask = nil }
            return self.generation
        }
        guard let generation else { return }
        let scaled = Self.downscaled(image)
        queue.async { [weak self] in
            self?.analyze(
                scaled, wantsMask: wantsMask, wantsFaces: wantsFaces, generation: generation)
        }
    }

    public func latest() -> Snapshot {
        lock.withLock {
            let snapshot = Snapshot(faces: faces, mask: mask)
            faces = nil
            return snapshot
        }
    }

    public func reset() {
        lock.withLock {
            generation += 1
            mask = nil
            faces = nil
        }
    }

    static func downscaled(_ image: CIImage) -> CIImage {
        let width = image.extent.width
        guard width > analysisWidth else { return image }
        let scale = analysisWidth / width
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    public static func topLeftRect(fromVision rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    private func analyze(_ image: CIImage, wantsMask: Bool, wantsFaces: Bool, generation: Int) {
        var requests: [VNRequest] = []
        if wantsMask { requests.append(segmentation) }
        if wantsFaces { requests.append(faceRequest) }
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform(requests)
        let nextMask =
            wantsMask
            ? segmentation.results?.first.map { CIImage(cvPixelBuffer: $0.pixelBuffer) } : nil
        let nextFaces =
            wantsFaces
            ? (faceRequest.results ?? []).map { Self.topLeftRect(fromVision: $0.boundingBox) } : nil
        lock.withLock {
            busy = false
            guard self.generation == generation else { return }
            if wantsMask, let nextMask { mask = nextMask }
            if let nextFaces { faces = nextFaces }
        }
    }
}
