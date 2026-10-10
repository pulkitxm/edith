import AppKit
import Compression
import CryptoKit
import EdithExtensionUI
import Foundation

@MainActor enum HostMarketplaceArtwork {
    static let keys = [
        "claude-accent", "edith-accent", "edith-blue", "edith-green", "edith-indigo",
        "edith-orange", "edith-pink", "edith-purple", "edith-red", "edith-teal",
        "finder-accent", "spotify-accent",
    ]
    static let resourceBundleName = "EdithHost_EdithHost.bundle"
    static let packedBytes = 220_928
    static let pixelBytes = 153_600
    static let packedDigest = "101f6c1abdaf28fd4b8f0b10b80a0aaa0b43bd4cb3c37e472bf02aac763079db"
    private static let cache = HostMarketplaceArtworkCache()

    static func swatches(theme: String) -> [NSImage] {
        cache.swatches(theme: theme, load: loadPixels)
    }

    static func image(_ key: String) -> NSImage? {
        guard keys.contains(key), let pixels = loadPixels() else { return nil }
        return image(key, pixels: pixels)
    }

    static func image(_ key: String, pixels: Data) -> NSImage? {
        guard let index = keys.firstIndex(of: key), pixels.count == keys.count * pixelBytes
        else { return nil }
        let start = index * pixelBytes
        let bytes = pixels.subdata(in: start..<(start + pixelBytes))
        guard let provider = CGDataProvider(data: bytes as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: 252, height: 150, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 1024, space: space,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGImageByteOrderInfo.order32Host.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 84, height: 50))
    }

    static func resourceURL(
        bundleURL: URL = Bundle(for: HostMarketplaceArtworkOwner.self).bundleURL
    ) -> URL? {
        let resources: URL
        if bundleURL.pathExtension == "appex" {
            let contents = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            guard contents.lastPathComponent == "Contents",
                bundleURL.deletingLastPathComponent().lastPathComponent == "Extensions",
                contents.deletingLastPathComponent().pathExtension == "app"
            else { return nil }
            resources = bundleURL.appendingPathComponent("Contents/Resources")
        } else if bundleURL.pathExtension == "app" {
            resources = bundleURL.appendingPathComponent("Contents/Resources")
        } else if bundleURL.pathExtension == "xctest" {
            resources = bundleURL.deletingLastPathComponent()
        } else {
            resources = bundleURL
        }
        return resources.appendingPathComponent(resourceBundleName)
            .appendingPathComponent("MarketplaceArtwork.lzma")
    }

    static func loadPixels() -> Data? {
        guard let url = resourceURL() else { return nil }
        return loadPixels(at: url)
    }

    static func loadPixels(at url: URL) -> Data? {
        let url = URL(fileURLWithPath: url.path)
        for directory in [
            url.deletingLastPathComponent(),
            url.deletingLastPathComponent().deletingLastPathComponent(),
        ] {
            guard
                let values = try? directory.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ]),
                values.isDirectory == true, values.isSymbolicLink != true
            else { return nil }
        }
        guard
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            values.fileSize == packedBytes,
            let packed = try? Data(contentsOf: url), packed.count == packedBytes
        else { return nil }
        return decode(packed)
    }

    static func decode(_ packed: Data) -> Data? {
        guard packed.count == packedBytes,
            SHA256.hash(data: packed).map({ String(format: "%02x", $0) }).joined() == packedDigest
        else { return nil }
        var pixels = Data(count: keys.count * pixelBytes)
        let count = pixels.withUnsafeMutableBytes { output in
            packed.withUnsafeBytes { input in
                compression_decode_buffer(
                    output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                    input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil,
                    COMPRESSION_LZMA)
            }
        }
        return count == pixels.count ? pixels : nil
    }
}

@MainActor final class HostMarketplaceArtworkCache {
    private var theme: String?
    private var images: [NSImage] = []

    func swatches(theme: String, load: () -> Data?) -> [NSImage] {
        let selected = AppTheme(storedName: theme).rawValue
        if self.theme == selected { return images }
        images =
            if let pixels = load() {
                ["edith-" + selected, "claude-accent", "finder-accent", "spotify-accent"].compactMap
                {
                    HostMarketplaceArtwork.image($0, pixels: pixels)
                }
            } else { [] }
        self.theme = selected
        return images
    }
}

private final class HostMarketplaceArtworkOwner: NSObject {}
