/*!
 *  Highlighter.swift
 *  Copyright 2026, Tony Smith
 *  Copyright 2016, Juan-Pablo Illanes
 *
 *  Licence: MIT
 */

import Foundation

public struct LineNumberData {

    public var numberStart: Int {
        get {
            return self.baseStart
        }

        set(newValue) {
            if newValue > 1 {
                self.baseStart = newValue
            } else {
                self.baseStart = 1
            }
        }
    }

    public var minWidth: Int {
        get {
            return self.baseMinWidth
        }
        set(newValue) {
            if newValue > 2 {
                self.baseMinWidth = newValue
            } else {
                self.baseMinWidth = 2
            }
        }
    }

    public var separator: String {
        get {
            return self.baseSeparator
        }

        set(newValue) {
            if newValue == "" {
                self.baseSeparator = "  "
            } else {
                self.baseSeparator = newValue
            }
        }
    }

    public var usingDarkTheme: Bool = false
    public var lineBreak: String = "\n"
    public var fontSize: CGFloat = 16.0

    private var baseSeparator: String = "  "
    private var baseStart: Int = 0
    private var baseMinWidth: Int = 2

    public init() {
        self.usingDarkTheme = false
        self.lineBreak = "\n"
        self.baseSeparator = "  "
        self.baseStart = 1
        self.baseMinWidth = 1
    }

    public init(usingDarkTheme: Bool = false, lineBreak: String = "\n", fontSize: CGFloat = 16.0) {
        self.usingDarkTheme = usingDarkTheme
        self.lineBreak = lineBreak
        self.fontSize = fontSize
    }
}
