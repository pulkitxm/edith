import AppKit

@MainActor
enum StatusItemSizing {
    static func titleLength(_ title: NSAttributedString) -> CGFloat {
        let button = NSStatusBarButton()
        button.attributedTitle = title
        button.sizeToFit()
        return ceil(button.frame.width)
    }
}
