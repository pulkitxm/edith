import Foundation

enum NotchProximity: Int, Comparable {
    case outside = 0
    case keepOpen = 1
    case open = 2

    static func < (lhs: NotchProximity, rhs: NotchProximity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum NotchGateTransition: Equatable {
    case none
    case schedule(deadline: TimeInterval)
    case cancelPending
    case opened
    case closed
}

struct NotchHoverGate {
    let openDwell: TimeInterval
    let closeGrace: TimeInterval

    private(set) var isOpen = false
    private var pendingTarget: Bool?
    private var pendingDeadline: TimeInterval?

    init(openDwell: TimeInterval = 0.1, closeGrace: TimeInterval = 0.4) {
        self.openDwell = max(0, openDwell)
        self.closeGrace = max(0, closeGrace)
    }

    var hasPending: Bool { pendingTarget != nil }

    mutating func sample(_ proximity: NotchProximity, now: TimeInterval) -> NotchGateTransition {
        let desired = desiredState(for: proximity)
        guard desired != isOpen else {
            guard pendingTarget != nil else { return .none }
            clearPending()
            return .cancelPending
        }
        if pendingTarget == desired, pendingDeadline != nil {
            return .none
        }
        let delay = desired ? openDwell : closeGrace
        let deadline = now + delay
        pendingTarget = desired
        pendingDeadline = deadline
        return .schedule(deadline: deadline)
    }

    mutating func fire(now: TimeInterval) -> NotchGateTransition {
        guard let target = pendingTarget, let deadline = pendingDeadline else { return .none }
        guard now >= deadline else { return .none }
        isOpen = target
        clearPending()
        return target ? .opened : .closed
    }

    mutating func forceOpen() {
        isOpen = true
        clearPending()
    }

    mutating func forceClosed() {
        isOpen = false
        clearPending()
    }

    private func desiredState(for proximity: NotchProximity) -> Bool {
        if isOpen {
            return proximity != .outside
        }
        return proximity == .open
    }

    private mutating func clearPending() {
        pendingTarget = nil
        pendingDeadline = nil
    }
}
