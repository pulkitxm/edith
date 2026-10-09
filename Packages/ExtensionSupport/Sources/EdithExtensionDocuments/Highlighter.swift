/*!
 *  Highlighter.swift
 *  Copyright 2026, Tony Smith
 *  Copyright 2016, Juan-Pablo Illanes
 *
 *  Licence: MIT
 */

import JavaScriptCore
#if os(OSX)
import AppKit
#else
import UIKit
#endif

open class Highlighter {

    open var theme: Theme! {
        didSet {
            themeChanged?(theme)
        }
    }

    open var themeChanged: ((Theme) -> Void)?

    open var ignoreIllegals = false

    private let hljs: JSValue
    private let bundle: Bundle
    private let htmlStart: String = "<"
    private let spanStart: String = "span class=\""
    private let spanStartClose: String = "\">"
    private let spanEnd: String = "/span>"
    private let htmlEscape: NSRegularExpression = try! NSRegularExpression(
        pattern: "&#?[a-zA-Z0-9]+?;", options: .caseInsensitive)

    public init?() {

        guard let bundle = DocumentResources.bundle else { return nil }

        guard let highlightPath: String = bundle.path(forResource: "highlight.min", ofType: "js")
        else {
            return nil
        }

        do {
            guard let context = JSContext() else {
                return nil
            }

            let highlightJs: String = try String(contentsOfFile: highlightPath)
            let _ = context.evaluateScript(highlightJs)

            guard let hljs = context.globalObject.objectForKeyedSubscript("hljs") else {
                return nil
            }

            self.hljs = hljs
            self.bundle = bundle
        } catch {
            return nil
        }

        guard setTheme("default-light") else {
            return nil
        }
    }

    public func highlight(_ code: String, as languageName: String? = nil, doFastRender: Bool = true)
        -> NSAttributedString?
    {

        return highlight(code, as: languageName, doFastRender: doFastRender, lineNumbering: nil)
    }

    public func highlight(
        _ code: String, as languageName: String? = nil, doFastRender: Bool = true,
        lineNumbering: LineNumberData? = nil
    ) -> NSAttributedString? {

        let returnValue: JSValue

        if let language = languageName {
            let options: [String: Any] = [
                "language": language, "ignoreIllegals": self.ignoreIllegals,
            ]
            returnValue = hljs.invokeMethod(
                "highlight",
                withArguments: [code, options])
        } else {
            returnValue = hljs.invokeMethod(
                "highlightAuto",
                withArguments: [code])
        }

        let renderedHTMLValue: JSValue? = returnValue.objectForKeyedSubscript("value")
        guard var renderedHTMLString: String = renderedHTMLValue!.toString() else {
            return nil
        }

        if renderedHTMLString == "undefined" {
            return nil
        }

        var returnAttrString: NSAttributedString? = nil

        if doFastRender {
            returnAttrString = processHTMLString(renderedHTMLString)!
        } else {
            renderedHTMLString =
                "<style>" + self.theme.lightTheme + "</style><pre><code class=\"hljs\">"
                + renderedHTMLString + "</code></pre>"
            let data = renderedHTMLString.data(using: String.Encoding.utf8)!
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]

            returnAttrString = try? NSMutableAttributedString(
                data: data, options: options, documentAttributes: nil)
        }

        if let lnd = lineNumbering, let ras = returnAttrString {
            returnAttrString = addLineNumbers(ras, lnd)
        }

        return returnAttrString
    }

    @discardableResult
    public func setTheme(_ themeName: String, withFont: String? = nil, ofSize: CGFloat? = nil)
        -> Bool
    {

        guard let themePath = self.bundle.path(forResource: themeName, ofType: "css") else {
            return false
        }

        var font: HRFont? = nil
        if let fontName: String = withFont {
            var size: CGFloat = 14.0
            if ofSize != nil {
                size = ofSize!
            }

            font = HRFont(name: fontName, size: size)
        }

        let themeString = try! String(contentsOfFile: themePath)
        self.theme = Theme(withTheme: themeString, usingFont: font)
        self.theme.name = themeName
        return true
    }

    public func availableThemes() -> [String] {

        let paths = bundle.paths(forResourcesOfType: "css", inDirectory: nil) as [NSString]
        var result = [String]()
        for path in paths {
            result.append(path.lastPathComponent.replacingOccurrences(of: ".css", with: ""))
        }

        return result
    }

    public func supportedLanguages() -> [String] {

        let res: JSValue? = hljs.invokeMethod("listLanguages", withArguments: [])
        return res!.toArray() as! [String]
    }

    private func processHTMLString(_ htmlString: String) -> NSAttributedString? {

        let resultString: NSMutableAttributedString = NSMutableAttributedString(string: "")
        var scanned: String? = nil
        var propStack: [String] = ["hljs"]
        let scanner: Scanner = Scanner(string: htmlString)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            scanned = scanner.scanUpToString(self.htmlStart)

            if let content = scanned, !content.isEmpty {
                resultString.append(self.theme.applyStyleToString(content, styleList: propStack))

                if scanner.isAtEnd {
                    continue
                }
            }

            scanner.skipNextCharacter()

            let nextChar: String = scanner.getNextCharacter(in: htmlString)
            if nextChar == "s" {
                _ = scanner.scanString(self.spanStart)

                scanned = scanner.scanUpToString(self.spanStartClose)

                _ = scanner.scanString(self.spanStartClose)

                if let content = scanned, !content.isEmpty {
                    propStack.append(content)
                }
            } else if nextChar == "/" {
                _ = scanner.scanString(self.spanEnd)
                propStack.removeLast()
            } else {
                let attrScannedString: NSAttributedString = self.theme.applyStyleToString(
                    "<", styleList: propStack)
                resultString.append(attrScannedString)
                scanner.skipNextCharacter()
            }
        }

        let results: [NSTextCheckingResult] = self.htmlEscape.matches(
            in: resultString.string,
            options: [.reportCompletion],
            range: NSMakeRange(0, resultString.length))
        var localOffset: Int = 0
        for result: NSTextCheckingResult in results {
            let fixedRange: NSRange = NSMakeRange(
                result.range.location - localOffset, result.range.length)
            let entity: String = (resultString.string as NSString).substring(with: fixedRange)
            if let decodedEntity = HTMLUtils.decode(entity) {
                resultString.replaceCharacters(in: fixedRange, with: String(decodedEntity))
                localOffset += (result.range.length - 1);
            }
        }

        return resultString
    }

    private func addLineNumbers(
        _ renderedCode: NSAttributedString, _ lineNumberingData: LineNumberData
    ) -> NSAttributedString? {

        let linedCode = NSMutableAttributedString()
        let lines = renderedCode.components(separatedBy: lineNumberingData.lineBreak)

        var formatCount = lineNumberingData.minWidth
        var lineIndex = lineNumberingData.numberStart > 1 ? lineNumberingData.numberStart - 1 : 0
        var lineCount: Int = lines.count + lineIndex
        while lineCount > 99 {
            formatCount += 1
            lineCount = lineCount / 100
        }

        let colour: HRColor = lineNumberingData.usingDarkTheme ? .white : .black

        let lineAtts: [NSAttributedString.Key: Any] = [
            .foregroundColor: colour.withAlphaComponent(0.2),
            .font: HRFont.monospacedSystemFont(
                ofSize: lineNumberingData.fontSize, weight: .ultraLight),
        ]

        let formatString = "%0\(formatCount)i"

        for line in lines {
            lineIndex += 1
            linedCode.append(
                NSAttributedString(
                    string: String(format: formatString, lineIndex), attributes: lineAtts))

            linedCode.append(
                NSAttributedString(string: lineNumberingData.separator, attributes: lineAtts))

            linedCode.append(line)
            linedCode.append(
                NSAttributedString(string: lineNumberingData.lineBreak, attributes: lineAtts))
        }

        return linedCode
    }
}
