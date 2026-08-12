import AppKit

enum AppArtwork {
    private static let resources = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        .compactMap { $0?.appendingPathComponent("Edith_Edith.bundle") }
        .compactMap(Bundle.init(url:))
        .first

    static let icon: NSImage? = {
        guard let url = resources?.url(forResource: "appicon", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}
