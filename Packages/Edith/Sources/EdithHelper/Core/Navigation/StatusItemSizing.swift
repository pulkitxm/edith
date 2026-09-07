import AppKit

@MainActor
enum StatusItemSizing {
    static func titleLength(_ title: NSAttributedString) -> CGFloat {
        ceil(title.size().width + 8)
    }
}
