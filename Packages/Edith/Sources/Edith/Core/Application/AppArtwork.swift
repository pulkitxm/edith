import AppKit

enum AppArtwork {
    static var icon: NSImage? {
        if let image = NSApp?.applicationIconImage { return image }
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
