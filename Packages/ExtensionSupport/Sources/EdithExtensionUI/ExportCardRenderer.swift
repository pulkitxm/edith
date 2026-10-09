import AppKit
import SwiftUI

@MainActor
public protocol ExportCardDeck {
    associatedtype Card: Identifiable & Hashable
    associatedtype Content: View
    var cards: [Card] { get }
    func title(for card: Card) -> String
    func filename(for card: Card) -> String
    @ViewBuilder func content(for card: Card) -> Content
}

public enum ExportCardRenderingError: LocalizedError {
    case unavailable
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The image could not be rendered."
        case .encodingFailed: "The image could not be encoded as PNG."
        }
    }
}

@MainActor
public enum ExportCardRenderer {
    public static let size = CGSize(width: 1_200, height: 800)

    private static func bitmap<Content: View>(_ content: Content, scale: CGFloat) throws -> CGImage
    {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let image = renderer.cgImage else { throw ExportCardRenderingError.unavailable }
        return image
    }

    public static func image<Content: View>(_ content: Content, scale: CGFloat = 2) throws
        -> NSImage
    {
        NSImage(cgImage: try bitmap(content, scale: scale), size: size)
    }

    public static func pngData<Content: View>(_ content: Content, scale: CGFloat = 2) throws -> Data
    {
        let bitmap = NSBitmapImageRep(cgImage: try bitmap(content, scale: scale))
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ExportCardRenderingError.encodingFailed
        }
        return data
    }
}
