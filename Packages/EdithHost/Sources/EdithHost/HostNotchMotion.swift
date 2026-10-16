import AppKit
import QuartzCore

struct HostNotchFade: Equatable {
    let duration: Double
    let delay: Double
}

enum HostNotchGlide: Equatable {
    case spring(response: Double, dampingFraction: Double)
    case easeOut(Double)
    case easeInOut(Double)

    static func resolve(reduceMotion: Bool, browser: Bool, expanded: Bool) -> HostNotchGlide {
        if reduceMotion { return .easeInOut(0.2) }
        if browser { return .easeOut(0.16) }
        return .spring(response: expanded ? 0.46 : 0.38, dampingFraction: 0.86)
    }

    func animation(keyPath: String, from: Any?, to: Any?) -> CAAnimation {
        let animation: CABasicAnimation
        switch self {
        case .spring(let response, let dampingFraction):
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.mass = 1
            spring.stiffness = pow(2 * Double.pi / response, 2)
            spring.damping = 4 * Double.pi * dampingFraction / response
            spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            animation = spring
        case .easeOut(let duration):
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        case .easeInOut(let duration):
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        animation.fromValue = from
        animation.toValue = to
        return animation
    }
}

enum HostNotchMotion {
    static func insertion(
        collapsedContent: Bool, browser: Bool, reduceMotion: Bool
    ) -> HostNotchFade {
        if reduceMotion { return HostNotchFade(duration: 0.2, delay: 0) }
        if collapsedContent { return HostNotchFade(duration: 0.2, delay: 0.35) }
        if browser { return HostNotchFade(duration: 0.12, delay: 0) }
        return HostNotchFade(duration: 0.2, delay: 0.12)
    }

    static func removal(
        collapsedContent: Bool, browser: Bool, reduceMotion: Bool
    ) -> HostNotchFade {
        if reduceMotion { return HostNotchFade(duration: 0.2, delay: 0) }
        if collapsedContent { return HostNotchFade(duration: 0.08, delay: 0) }
        if browser { return HostNotchFade(duration: 0.06, delay: 0) }
        return HostNotchFade(duration: 0.1, delay: 0)
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    @MainActor static func fade(_ view: NSView, from: Float, to: Float, _ fade: HostNotchFade) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "notchFade")
        layer.opacity = to
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = fade.duration
        animation.beginTime = CACurrentMediaTime() + fade.delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "notchFade")
    }
}
