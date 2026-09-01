import AppKit

struct TerminalCommandClickGesture {
    private(set) var origin: NSPoint?
    private(set) var candidate: String?
    private(set) var dragged = false

    mutating func begin(active: Bool, at point: NSPoint, candidate: String?) {
        guard active else {
            reset()
            return
        }
        origin = point
        self.candidate = candidate
        dragged = false
    }

    mutating func move(to point: NSPoint) {
        guard let origin else { return }
        let x = point.x - origin.x
        let y = point.y - origin.y
        if (x * x) + (y * y) >= 16 { dragged = true }
    }

    mutating func finish(active: Bool, opened: Bool, candidate current: String?) -> String? {
        defer { reset() }
        guard active, origin != nil, !dragged, !opened else { return nil }
        return current ?? candidate
    }

    mutating func reset() {
        origin = nil
        candidate = nil
        dragged = false
    }
}
