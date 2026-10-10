import Foundation

public enum GhosttyFontZoom: Sendable {
    case increase
    case decrease
    case reset
}

public enum GhosttyPaneAction: Equatable, Sendable {
    public enum Direction: String, Sendable { case up, down, left, right }
    public enum Focus: String, Sendable { case previous, next, up, down, left, right }
    case newTab
    case selectTab(Int32)
    case split(Direction)
    case focus(Focus)
    case resize(Direction, UInt16)
    case equalize
    case toggleZoom
}
