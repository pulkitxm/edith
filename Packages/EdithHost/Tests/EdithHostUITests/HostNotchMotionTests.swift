import AppKit
import Testing

@testable import EdithHost

@MainActor
@Suite struct HostNotchMotionTests {
    @Test func glideMatchesTheOriginalSprings() {
        #expect(
            HostNotchGlide.resolve(reduceMotion: false, browser: false, expanded: true)
                == .spring(response: 0.46, dampingFraction: 0.86))
        #expect(
            HostNotchGlide.resolve(reduceMotion: false, browser: false, expanded: false)
                == .spring(response: 0.38, dampingFraction: 0.86))
        #expect(
            HostNotchGlide.resolve(reduceMotion: false, browser: true, expanded: true)
                == .easeOut(0.16))
        #expect(
            HostNotchGlide.resolve(reduceMotion: true, browser: true, expanded: true)
                == .easeInOut(0.2))
    }

    @Test func springAnimationUsesSwiftUIConversion() throws {
        let glide = HostNotchGlide.spring(response: 0.46, dampingFraction: 0.86)
        let animation = try #require(
            glide.animation(keyPath: "path", from: nil, to: nil) as? CASpringAnimation)
        #expect(abs(animation.stiffness - pow(2 * Double.pi / 0.46, 2)) < 0.0001)
        #expect(abs(animation.damping - 4 * Double.pi * 0.86 / 0.46) < 0.0001)
        #expect(animation.mass == 1)
    }

    @Test func fadeTimingsMatchTheOriginalTransitions() {
        #expect(
            HostNotchMotion.insertion(collapsedContent: false, browser: false, reduceMotion: false)
                == HostNotchFade(duration: 0.2, delay: 0.12))
        #expect(
            HostNotchMotion.insertion(collapsedContent: false, browser: true, reduceMotion: false)
                == HostNotchFade(duration: 0.12, delay: 0))
        #expect(
            HostNotchMotion.insertion(collapsedContent: true, browser: false, reduceMotion: false)
                == HostNotchFade(duration: 0.2, delay: 0.35))
        #expect(
            HostNotchMotion.removal(collapsedContent: false, browser: false, reduceMotion: false)
                == HostNotchFade(duration: 0.1, delay: 0))
        #expect(
            HostNotchMotion.removal(collapsedContent: false, browser: true, reduceMotion: false)
                == HostNotchFade(duration: 0.06, delay: 0))
        #expect(
            HostNotchMotion.removal(collapsedContent: true, browser: false, reduceMotion: false)
                == HostNotchFade(duration: 0.08, delay: 0))
        #expect(
            HostNotchMotion.insertion(collapsedContent: true, browser: false, reduceMotion: true)
                == HostNotchFade(duration: 0.2, delay: 0))
    }
}
