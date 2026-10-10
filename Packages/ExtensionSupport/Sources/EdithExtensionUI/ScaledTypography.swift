import EdithExtensionSupport
import AppKit
import SwiftUI

extension Font {
    public static func edithText(_ style: Font.TextStyle, design: Font.Design = .default) -> Font {
        let textStyle: NSFont.TextStyle
        switch style {
        case .largeTitle: textStyle = .largeTitle
        case .title: textStyle = .title1
        case .title2: textStyle = .title2
        case .title3: textStyle = .title3
        case .headline: textStyle = .headline
        case .subheadline: textStyle = .subheadline
        case .body: textStyle = .body
        case .callout: textStyle = .callout
        case .footnote: textStyle = .footnote
        case .caption: textStyle = .caption1
        case .caption2: textStyle = .caption2
        @unknown default: textStyle = .body
        }
        return .system(
            size: UIScale.pt(NSFont.preferredFont(forTextStyle: textStyle).pointSize),
            weight: style == .headline ? .semibold : .regular, design: design)
    }
}
