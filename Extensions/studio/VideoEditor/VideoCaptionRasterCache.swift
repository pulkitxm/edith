import CoreImage
import Foundation

final class VideoCaptionRasterCache: @unchecked Sendable {
    struct Statistics {
        let entries: Int
        let bytes: Int
        let hits: Int
        let misses: Int
    }

    private struct Source {
        let annotation: VideoProject.Annotation
        let style: VideoCaptionStyle
    }

    private struct Key: Equatable {
        let id: String
        let size: CGSize
    }

    private struct Entry {
        let key: Key
        let image: CIImage
        let cost: Int
    }

    static let maximumBytes = 64 * 1024 * 1024
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let sources: [String: Source]
    private var entries: [Entry] = []
    private var bytes = 0
    private var hits = 0
    private var misses = 0

    init(annotations: [VideoProject.Annotation]) {
        sources = Dictionary(
            uniqueKeysWithValues: annotations.compactMap { annotation in
                annotation.captionStyle.map {
                    (annotation.id, Source(annotation: annotation, style: $0))
                }
            })
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(entries: entries.count, bytes: bytes, hits: hits, misses: misses)
        }
    }

    func image(for id: String, size: CGSize) -> CIImage? {
        lock.withLock {
            let key = Key(id: id, size: size)
            if let index = entries.firstIndex(where: { $0.key == key }) {
                hits += 1
                let entry = entries.remove(at: index)
                entries.append(entry)
                return entry.image
            }
            guard let source = sources[id] else { return nil }
            misses += 1
            return autoreleasepool {
                guard
                    let rendered = VideoStyledCaptionImage.make(
                        source.annotation, style: source.style, size: size),
                    let raster = context.createCGImage(
                        rendered, from: rendered.extent,
                        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                else { return nil }
                let image = CIImage(cgImage: raster)
                let cost = raster.bytesPerRow * raster.height
                guard cost <= Self.maximumBytes else { return image }
                while !entries.isEmpty && (entries.count >= 2 || bytes + cost > Self.maximumBytes) {
                    bytes -= entries.removeFirst().cost
                }
                entries.append(Entry(key: key, image: image, cost: cost))
                bytes += cost
                return image
            }
        }
    }
}
