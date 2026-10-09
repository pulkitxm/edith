/*!
 *  Highlighter.swift
 *  Copyright 2026, Tony Smith
 *  Copyright 2016, Juan-Pablo Illanes
 *
 *  Licence: MIT
 */

#if os(OSX)
import AppKit
#elseif os(iOS)
import UIKit
#endif

extension NSMutableAttributedString {

    func addParaStyle(with paraStyle: NSParagraphStyle) {

        beginEditing()
        self.enumerateAttribute(.paragraphStyle, in: NSMakeRange(0, self.length)) {
            (value, range, stop) in
            if let _ = value as? NSParagraphStyle {
                removeAttribute(.paragraphStyle, range: range)
                addAttribute(.paragraphStyle, value: paraStyle, range: range)
            }
        }
        endEditing()
    }
}

extension NSAttributedString {

    func components(separatedBy separator: String) -> [NSAttributedString] {

        var parts: [NSAttributedString] = []
        let subStrings = self.string.components(separatedBy: separator)
        var range = NSRange(location: 0, length: 0)
        for string in subStrings {
            range.length = string.utf16.count
            let attributedString = attributedSubstring(from: range)
            parts.append(attributedString)
            range.location += range.length + separator.utf16.count
        }
        return parts
    }
}

extension Scanner {

    func getNextCharacter(in outer: String) -> String {

        let string: NSString = self.string as NSString
        let idx: Int = self.currentIndex.utf16Offset(in: outer)
        let nextChar: String = string.substring(with: NSMakeRange(idx, 1))
        return nextChar
    }

    func skipNextCharacter() {

        self.currentIndex = self.string.index(after: self.currentIndex)
    }
}

#if os(OSX)
extension NSColor {

    static func hexToColour(_ hex: String) -> NSColor {

        var colourString: String = hex.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if (colourString.hasPrefix("#")) {
            let index = colourString.index(colourString.startIndex, offsetBy: 1)
            colourString = String(colourString[index...])
        }

        if colourString.count != 8 && colourString.count != 6 {
            return .red
        }

        func hexToFloat(_ hs: String) -> CGFloat {
            return CGFloat(UInt8(hs, radix: 16) ?? 255)
        }

        let cns: NSString = colourString as NSString
        let red: CGFloat = hexToFloat(cns.substring(with: NSRange(location: 0, length: 2))) / 255.0
        let green: CGFloat =
            hexToFloat(cns.substring(with: NSRange(location: 2, length: 2))) / 255.0
        let blue: CGFloat = hexToFloat(cns.substring(with: NSRange(location: 4, length: 2))) / 255.0
        let alpha: CGFloat =
            hexToFloat(cns.substring(with: NSRange(location: 6, length: 2))) / 255.0
        return NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#elseif os(iOS)
extension UIColor {

    var alphaComponent: CGFloat {

        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        var alpha: CGFloat = 0.0

        self.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return alpha
    }

    static var labelColor: UIColor {

        return .label
    }

    static func hexToColour(_ hex: String) -> UIColor {

        var colourString: String = hex.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if (colourString.hasPrefix("#")) {
            let index = colourString.index(colourString.startIndex, offsetBy: 1)
            colourString = String(colourString[index...])
        }

        if colourString.count != 8 && colourString.count != 6 {
            return .red
        }

        func hexToFloat(_ hs: String) -> CGFloat {
            return CGFloat(UInt8(hs, radix: 16) ?? 255)
        }

        let cns: NSString = colourString as NSString
        let red: CGFloat = hexToFloat(cns.substring(with: NSRange(location: 0, length: 2))) / 255.0
        let green: CGFloat =
            hexToFloat(cns.substring(with: NSRange(location: 2, length: 2))) / 255.0
        let blue: CGFloat = hexToFloat(cns.substring(with: NSRange(location: 4, length: 2))) / 255.0
        let alpha: CGFloat =
            hexToFloat(cns.substring(with: NSRange(location: 6, length: 2))) / 255.0
        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif
