import AppKit

@MainActor
public enum StatusItemSizing {
    public static func titleLength(_ title: NSAttributedString) -> CGFloat {
        ceil(title.size().width + 8)
    }
}
