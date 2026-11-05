import AppKit
import EdithIcons

extension EdithIcon {
    public static func terminalOverlay<Icons>(
        _ make: (
            _ link: NSImage, _ file: NSImage, _ previous: NSImage, _ next: NSImage, _ close: NSImage
        ) -> Icons
    ) -> Icons {
        make(
            external.nsImage(size: 12), folder.nsImage(size: 12), chevronUp.nsImage(),
            chevronDown.nsImage(), close.nsImage())
    }
}
