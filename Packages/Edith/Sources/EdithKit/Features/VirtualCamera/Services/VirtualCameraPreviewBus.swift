import CoreVideo
import Darwin
import Foundation

public final class VirtualCameraPreviewBus: @unchecked Sendable {
    public static let previewWidth = 640
    public static let previewHeight = 360

    private static let pixelBytes = previewWidth * previewHeight * 4
    private static let regionSize = Slot.pixels + pixelBytes

    private enum Slot {
        static let wanted = 0
        static let generation = 8
        static let width = 16
        static let height = 20
        static let pixels = 128
    }

    private let file: URL
    private let unlinkOnClose: Bool
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var base: UnsafeMutableRawPointer?
    private var seen: UInt64 = 0
    private var pool: CVPixelBufferPool?
    private var closed = false

    public static func sharedFile() -> URL {
        DataRoot.virtualCamera.appendingPathComponent("preview.bin")
    }

    public init(file: URL = VirtualCameraPreviewBus.sharedFile(), unlinkOnClose: Bool = false) {
        self.file = file
        self.unlinkOnClose = unlinkOnClose
    }

    deinit { close() }

    public func close() {
        lock.lock()
        closed = true
        let pointer = base
        let descriptor = fd
        base = nil
        fd = -1
        lock.unlock()
        if let pointer { munmap(pointer, Self.regionSize) }
        if descriptor >= 0 { Darwin.close(descriptor) }
        if unlinkOnClose { try? FileManager.default.removeItem(at: file) }
    }

    public func setWanted(_ wanted: Bool) {
        guard let base = region() else { return }
        base.storeBytes(of: wanted ? Int32(1) : 0, toByteOffset: Slot.wanted, as: Int32.self)
    }

    public var isWanted: Bool {
        guard let base = region() else { return false }
        return base.load(fromByteOffset: Slot.wanted, as: Int32.self) != 0
    }

    public func publish(_ buffer: CVPixelBuffer) {
        guard let base = region(), base.load(fromByteOffset: Slot.wanted, as: Int32.self) != 0
        else { return }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(buffer) else { return }
        let srcWidth = CVPixelBufferGetWidth(buffer)
        let srcHeight = CVPixelBufferGetHeight(buffer)
        guard srcWidth > 0, srcHeight > 0 else { return }
        let generation = base.load(fromByteOffset: Slot.generation, as: UInt64.self) &+ 1
        base.storeBytes(of: generation | 1, toByteOffset: Slot.generation, as: UInt64.self)
        OSMemoryBarrier()
        downsample(
            from: source, width: srcWidth, height: srcHeight,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            into: base.advanced(by: Slot.pixels))
        base.storeBytes(of: Int32(Self.previewWidth), toByteOffset: Slot.width, as: Int32.self)
        base.storeBytes(of: Int32(Self.previewHeight), toByteOffset: Slot.height, as: Int32.self)
        OSMemoryBarrier()
        base.storeBytes(of: (generation | 1) &+ 1, toByteOffset: Slot.generation, as: UInt64.self)
    }

    public func latest() -> CVPixelBuffer? {
        guard let base = region() else { return nil }
        for _ in 0..<2 {
            let generation = base.load(fromByteOffset: Slot.generation, as: UInt64.self)
            if generation == 0 || generation & 1 == 1 || generation == seen { return nil }
            OSMemoryBarrier()
            let width = Int(base.load(fromByteOffset: Slot.width, as: Int32.self))
            let height = Int(base.load(fromByteOffset: Slot.height, as: Int32.self))
            guard width == Self.previewWidth, height == Self.previewHeight,
                let buffer = makeBuffer()
            else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let destination = CVPixelBufferGetBaseAddress(buffer) {
                let row = CVPixelBufferGetBytesPerRow(buffer)
                let source = base.advanced(by: Slot.pixels)
                if row == width * 4 {
                    destination.copyMemory(from: source, byteCount: width * height * 4)
                } else {
                    for y in 0..<height {
                        destination.advanced(by: y * row).copyMemory(
                            from: source.advanced(by: y * width * 4), byteCount: width * 4)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            OSMemoryBarrier()
            guard base.load(fromByteOffset: Slot.generation, as: UInt64.self) == generation else {
                continue
            }
            seen = generation
            return buffer
        }
        return nil
    }

    private func region() -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        if closed { return nil }
        if let base { return base }
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let descriptor = file.path.withCString { Darwin.open($0, O_RDWR) }
        guard descriptor >= 0 else { return nil }
        guard ftruncate(descriptor, off_t(Self.regionSize)) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        let pointer = mmap(
            nil, Self.regionSize, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        guard let pointer, pointer != MAP_FAILED else {
            Darwin.close(descriptor)
            return nil
        }
        fd = descriptor
        base = pointer
        return pointer
    }

    private func makeBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: Self.previewWidth,
                kCVPixelBufferHeightKey: Self.previewHeight,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func downsample(
        from source: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
        into destination: UnsafeMutableRawPointer
    ) {
        let dstWidth = Self.previewWidth
        let dstHeight = Self.previewHeight
        let dstRow = dstWidth * 4
        for y in 0..<dstHeight {
            let sy = min(y * height / dstHeight, height - 1)
            let srcLine = source.advanced(by: sy * bytesPerRow)
            let dstLine = destination.advanced(by: y * dstRow)
            for x in 0..<dstWidth {
                let sx = min(x * width / dstWidth, width - 1)
                let pixel = srcLine.load(fromByteOffset: sx * 4, as: UInt32.self)
                dstLine.storeBytes(of: pixel, toByteOffset: x * 4, as: UInt32.self)
            }
        }
    }
}
