import AppKit

struct HerdrTab: Identifiable, Equatable {
    let id: String
    var layout: HerdrLayout
    var focused: String
    var zoomed: String?

    init(id: String = UUID().uuidString, agentID: String) {
        self.id = id
        layout = .pane(agentID)
        focused = agentID
    }

    var agentIDs: [String] { layout.panes }
    var isSplit: Bool { layout.paneCount > 1 }
}

enum HerdrLayoutKey: Equatable {
    case focus(InsertSide)
    case cycle(backwards: Bool)
    case zoom

    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> HerdrLayoutKey? {
        let flags = modifiers.chordOnly
        if flags == [.command, .shift], keyCode == 36 { return .zoom }
        if keyCode == 50, flags == .option { return .cycle(backwards: false) }
        if keyCode == 50, flags == [.option, .shift] { return .cycle(backwards: true) }
        guard flags == [.command, .option] else { return nil }
        switch keyCode {
        case 123: return .focus(.left)
        case 124: return .focus(.right)
        case 125: return .focus(.bottom)
        case 126: return .focus(.top)
        default: return nil
        }
    }
}
