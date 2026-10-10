import Foundation

public enum DocumentRenderer {
    public static var isAvailable: Bool { Highlighter() != nil }
}
