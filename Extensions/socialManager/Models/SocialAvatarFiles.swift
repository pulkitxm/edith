import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct SocialAvatarFiles: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func thumbnail(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256,
                ] as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    public func importImage(_ source: URL) throws -> String {
        let data = try Self.thumbnail(source)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let name = UUID().uuidString + ".png"
        let file = try url(name)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return name
    }

    public func read(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    public func remove(_ name: String) throws { try FileManager.default.removeItem(at: url(name)) }

    private func url(_ name: String) throws -> URL {
        guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent,
            name.hasSuffix(".png")
        else { throw CocoaError(.fileReadInvalidFileName) }
        return directory.appendingPathComponent(name)
    }
}
