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

private typealias HRThemeDict = [String: [AnyHashable: AnyObject]]
private typealias HRThemeStringDict = [String: [String: String]]

public class Theme {

    public var codeFont: HRFont!
    public var boldCodeFont: HRFont!
    public var italicCodeFont: HRFont!
    public var themeBackgroundColour: HRColor!
    public var lineSpacing: CGFloat = 0.0
    public var paraSpacing: CGFloat = 0.0
    public var isDark: Bool = false
    public var fontSize: CGFloat = 18.0
    public var name: String = ""

    private var themeDict: HRThemeDict!
    private var strippedTheme: HRThemeStringDict!
    internal let theme: String
    internal var lightTheme: String!

    init(withTheme: String = "default", usingFont: HRFont? = nil) {

        self.name = withTheme
        self.theme = withTheme

        if let font: HRFont = usingFont {
            setCodeFont(font)
        } else if let font = HRFont(name: "courier", size: 14.0) {
            setCodeFont(font)
        } else {
            setCodeFont(HRFont.systemFont(ofSize: 14.0))
        }

        self.strippedTheme = stripTheme(self.theme)
        self.lightTheme = strippedThemeToString(self.strippedTheme)
        self.themeDict = strippedThemeToTheme(self.strippedTheme)

        var backgroundColourHex: String? = self.strippedTheme[".hljs"]?["background"]
        if backgroundColourHex == nil {
            backgroundColourHex = self.strippedTheme[".hljs"]?["background-color"]
        }

        if let bgColourHex = backgroundColourHex {
            self.themeBackgroundColour = colourFromHexString(bgColourHex)
        } else {
            self.themeBackgroundColour = HRColor.white
        }
    }

    public func setCodeFont(_ font: HRFont) {

        self.codeFont = font
        self.fontSize = font.pointSize

        #if os(OSX)
        let boldDescriptor = NSFontDescriptor(fontAttributes: [
            .family: font.familyName!,
            .face: "Bold",
        ])
        let italicDescriptor = NSFontDescriptor(fontAttributes: [
            .family: font.familyName!,
            .face: "Italic",
        ])
        let obliqueDescriptor = NSFontDescriptor(fontAttributes: [
            .family: font.familyName!,
            .face: "Oblique",
        ])
        #else
        let boldDescriptor = UIFontDescriptor(fontAttributes: [
            UIFontDescriptor.AttributeName.family: font.familyName,
            UIFontDescriptor.AttributeName.face: "Bold",
        ])
        let italicDescriptor = UIFontDescriptor(fontAttributes: [
            UIFontDescriptor.AttributeName.family: font.familyName,
            UIFontDescriptor.AttributeName.face: "Italic",
        ])
        let obliqueDescriptor = UIFontDescriptor(fontAttributes: [
            UIFontDescriptor.AttributeName.family: font.familyName,
            UIFontDescriptor.AttributeName.face: "Oblique",
        ])
        #endif

        self.boldCodeFont = HRFont(descriptor: boldDescriptor, size: font.pointSize)
        self.italicCodeFont = HRFont(descriptor: italicDescriptor, size: font.pointSize)

        if (self.italicCodeFont == nil || self.italicCodeFont.familyName != font.familyName) {
            self.italicCodeFont = HRFont(descriptor: obliqueDescriptor, size: font.pointSize)
        }

        if (self.italicCodeFont == nil) {
            self.italicCodeFont = font
        }

        if (self.boldCodeFont == nil) {
            self.boldCodeFont = font
        }

        if (self.themeDict != nil) {
            self.themeDict = strippedThemeToTheme(self.strippedTheme)
        }
    }

    internal func applyStyleToString(_ string: String, styleList: [String]) -> NSAttributedString {

        let returnString: NSAttributedString

        let spacedParaStyle: NSMutableParagraphStyle = NSMutableParagraphStyle()
        spacedParaStyle.lineSpacing = (self.lineSpacing >= 0.0 ? self.lineSpacing : 0.0)
        spacedParaStyle.paragraphSpacing = (self.paraSpacing >= 0.0 ? self.paraSpacing : 0.0)

        if styleList.count > 0 {
            var embeddedAlpha: HRColor? = nil
            var attrs = [AttributedStringKey: Any]()
            attrs[.font] = self.codeFont
            attrs[.paragraphStyle] = spacedParaStyle
            for style in styleList {
                let aStyle: String
                if let spaceIndex = style.firstIndex(of: " ") {
                    aStyle = String(style[style.startIndex..<spaceIndex])
                } else {
                    aStyle = style
                }

                if let themeStyle = self.themeDict[aStyle] as? [AttributedStringKey: Any] {
                    for (attrName, attrValue) in themeStyle {
                        if attrName == .strokeColor {
                            embeddedAlpha = attrValue as? HRColor
                            continue
                        }

                        attrs.updateValue(attrValue, forKey: attrName)
                    }
                } else {
                    #if DEBUG
                    print("WARNING MISSING STYLE in \(self.name): \(aStyle)")
                    #endif
                }
            }

            if let alpha = embeddedAlpha {
                var base: HRColor = .labelColor
                if attrs[.foregroundColor] != nil {
                    base = attrs[.foregroundColor]! as! HRColor
                }

                attrs[.foregroundColor] = base.withAlphaComponent(alpha.alphaComponent)
            }

            returnString = NSAttributedString(string: string, attributes: attrs)
        } else {
            returnString = NSAttributedString(
                string: string,
                attributes: [
                    .font: self.codeFont as Any,
                    .paragraphStyle: spacedParaStyle,
                ])
        }

        return returnString
    }

    private func stripTheme(_ css: String) -> HRThemeStringDict {

        var resultDict = [String: [String: String]]()
        var returnDict = [String: [String: String]]()

        let cssRegex = try! NSRegularExpression(
            pattern: #"(?:/\*[\s\S]*?\*/\s*|([^{}]+?)\s*\{([^}]*)\})"#)
        cssRegex.enumerateMatches(in: css, range: NSRange(css.startIndex..., in: css)) {
            match, _, _ in
            guard let match,
                let nameListRange = Range(match.range(at: 1), in: css),
                let formatListRange = Range(match.range(at: 2), in: css)
            else { return }
            let nameList = String(css[nameListRange])
            let formatList = String(css[formatListRange])

            var attributes = [String: String]()
            let formatPairs = formatList.trimmingCharacters(in: .whitespacesAndNewlines).components(
                separatedBy: ";")
            for formatPair in formatPairs {
                let formatParts = formatPair.components(separatedBy: ":")
                if (formatParts.count == 2) {
                    attributes[formatParts[0]] = formatParts[1]
                }
            }

            if attributes.count > 0 {
                if resultDict[nameList] != nil {
                    let existingAttributes: [String: String] = resultDict[nameList]!
                    resultDict[nameList] = existingAttributes.merging(
                        attributes, uniquingKeysWith: { (first, _) in first })
                } else {
                    resultDict[nameList] = attributes
                }
            }
        }

        for (keys, result) in resultDict {
            let keyArray = keys.trimmingCharacters(in: .whitespacesAndNewlines).components(
                separatedBy: ",")
            for key in keyArray {
                var properties = [String: String]()
                if returnDict[key] != nil {
                    properties = returnDict[key]!
                }

                for (propName, propValue) in result {
                    properties.updateValue(propValue, forKey: propName)
                }

                returnDict[key] = properties
            }
        }

        return returnDict
    }

    private func strippedThemeToString(_ themeStringDict: HRThemeStringDict) -> String {

        var resultString: String = ""
        for (key, props) in themeStringDict {
            resultString += (key + "{")
            for (cssProp, val) in props {
                if key != ".hljs"
                    || (cssProp.lowercased() != "background-color"
                        && cssProp.lowercased() != "background")
                {
                    resultString += "\(cssProp):\(val);"
                }
            }

            resultString += "}"
        }

        return resultString
    }

    private func strippedThemeToTheme(_ themeStringDict: HRThemeStringDict) -> HRThemeDict {

        var returnTheme = HRThemeDict()
        for (className, props) in themeStringDict {
            var atttributes = [AttributedStringKey: AnyObject]()
            for (key, prop) in props {
                switch key {
                case "color":
                    atttributes[attributeForCSSKey(key)] = colourFromHexString(prop)
                case "font-style":
                    atttributes[attributeForCSSKey(key)] = fontForCSSStyle(prop)
                case "font-weight":
                    atttributes[attributeForCSSKey(key)] = fontForCSSStyle(prop)
                case "background-color":
                    atttributes[attributeForCSSKey(key)] = colourFromHexString(prop)
                case "opacity":
                    var alphaValue = 1.0
                    if let alpha = Double(prop) {
                        alphaValue = alpha
                    }

                    if alphaValue < 0.0 { alphaValue = 0.0 }
                    if alphaValue > 1.0 { alphaValue = 1.0 }
                    atttributes[attributeForCSSKey(key)] = HRColor(
                        red: 0.0, green: 0.0, blue: 0.0, alpha: alphaValue)
                default:
                    break
                }
            }

            if atttributes.count > 0 {
                let key: String = className.replacingOccurrences(of: ".", with: "")
                returnTheme[key] = atttributes
            }
        }

        return returnTheme
    }

    internal func fontForCSSStyle(_ fontStyle: String) -> HRFont {

        switch fontStyle {
        case "bold", "bolder", "600", "700", "800", "900":
            return self.boldCodeFont
        case "italic", "oblique":
            return self.italicCodeFont
        default:
            return self.codeFont
        }
    }

    internal func attributeForCSSKey(_ key: String) -> AttributedStringKey {

        switch key {
        case "color":
            return .foregroundColor
        case "font-weight":
            return .font
        case "font-style":
            return .font
        case "background-color":
            return .backgroundColor
        case "opacity":
            return .strokeColor
        default:
            return .font
        }
    }

    internal func colourFromHexString(_ colourValue: String) -> HRColor {

        var colourString: String = colourValue.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines)

        if (colourString.hasPrefix("#")) {
            colourString = String(colourString.dropFirst(1))
        } else {
            switch colourString {
            case "red":
                return .red
            case "green":
                return .green
            case "blue":
                return .blue
            case "white":
                return HRColor(white: 1.0, alpha: 1.0)
            case "black":
                return HRColor(white: 0.0, alpha: 1.0)
            case "gray":
                return .hexToColour("AAAAAA")
            case "navy":
                return .hexToColour("07188D")
            case "silver":
                return .hexToColour("D6D6D6")
            case "olive":
                return .hexToColour("929000")
            case "purple":
                return .hexToColour("942193")
            case "maroon":
                return .hexToColour("941751")
            default:
                return .gray
            }
        }

        if colourString.count != 8 && colourString.count != 6 && colourString.count != 3 {
            #if DEBUG
            return .red
            #else
            return .gray
            #endif
        }

        var r: UInt64 = 0, g: UInt64 = 0, b: UInt64 = 0, a: UInt64 = 0
        var divisor: CGFloat
        var alpha: CGFloat = 1.0

        if colourString.count == 6 || colourString.count == 8 {
            let rString = String(colourString.dropLast(colourString.count - 2))
            let gString = String(colourString.dropFirst(2).dropLast(colourString.count - 4))
            let bString = String(colourString.dropFirst(4).dropLast(colourString.count - 6))

            Scanner(string: rString).scanHexInt64(&r)
            Scanner(string: gString).scanHexInt64(&g)
            Scanner(string: bString).scanHexInt64(&b)

            divisor = 255.0

            if colourString.count == 8 {
                let aString = String(colourString.dropFirst(6))
                Scanner(string: aString).scanHexInt64(&a)
                alpha = CGFloat(a) / divisor
            }
        } else {
            let rString = String(colourString.dropLast(2))
            let gString = String(colourString.dropFirst(1).dropLast(1))
            let bString = String(colourString.dropFirst(2))

            Scanner(string: rString).scanHexInt64(&r)
            Scanner(string: gString).scanHexInt64(&g)
            Scanner(string: bString).scanHexInt64(&b)

            divisor = 15.0
        }

        return HRColor(
            red: CGFloat(r) / divisor, green: CGFloat(g) / divisor, blue: CGFloat(b) / divisor,
            alpha: alpha)
    }
}
