import Testing

@testable import EdithKit

@Suite struct FocusDimMathTests {
    @Test func clampsIntensityIntoRange() {
        #expect(FocusDimMath.clampIntensity(0.5) == 0.5)
        #expect(FocusDimMath.clampIntensity(-1) == 0)
        #expect(FocusDimMath.clampIntensity(5) == 0.9)
    }

    @Test func clampIntensitySurvivesGarbage() {
        #expect(FocusDimMath.clampIntensity(.nan) == FocusDimMath.defaultIntensity)
        #expect(FocusDimMath.clampIntensity(.infinity) == 0.9)
        #expect(FocusDimMath.clampIntensity(-.infinity) == 0)
    }

    @Test func clampAnimationDurationSurvivesInfinity() {
        #expect(FocusDimMath.clampAnimationDuration(.infinity) == 1.0)
        #expect(FocusDimMath.clampAnimationDuration(-.infinity) == 0.05)
    }

    @Test func clampsAnimationDurationIntoRange() {
        #expect(FocusDimMath.clampAnimationDuration(0.25) == 0.25)
        #expect(FocusDimMath.clampAnimationDuration(0) == 0.05)
        #expect(FocusDimMath.clampAnimationDuration(10) == 1.0)
    }

    @Test func clampAnimationDurationSurvivesGarbage() {
        #expect(FocusDimMath.clampAnimationDuration(.nan) == FocusDimMath.defaultAnimationDuration)
    }

    @Test func displayModeFallsBackWhenUnrecognized() {
        #expect(FocusDimDisplayMode.from("perScreenFront") == .perScreenFront)
        #expect(FocusDimDisplayMode.from("dimUnfocused") == .dimUnfocused)
        #expect(FocusDimDisplayMode.from("bogus") == .perScreenFront)
        #expect(FocusDimDisplayMode.from(nil) == .perScreenFront)
    }
}
