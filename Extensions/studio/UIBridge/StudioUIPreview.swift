import AppKit
import EdithStudio
import Foundation

struct StudioUIPreview: Codable, Sendable {
    let before: Data
    let after: Data

    init(_ preview: StudioPreviewImage) throws {
        guard
            let before = NSBitmapImageRep(cgImage: preview.before)
                .representation(using: .png, properties: [:]),
            let after = NSBitmapImageRep(cgImage: preview.after)
                .representation(using: .png, properties: [:])
        else {
            throw StudioError.failed("The preview could not be encoded.")
        }
        self.before = before
        self.after = after
    }
}
