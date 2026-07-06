import Testing
@testable import EdithMenuBar

@Suite struct MeterMathTests {
    @Test func mapsTheAudibleWindow() {
        #expect(MeterMath.level(fromPower: 0) == 1.0)
        #expect(MeterMath.level(fromPower: -25) == 0.5)
        #expect(MeterMath.level(fromPower: -50) == 0.0)
    }

    @Test func clampsAndSurvivesGarbage() {
        #expect(MeterMath.level(fromPower: -160) == 0.0)
        #expect(MeterMath.level(fromPower: 10) == 1.0)
        #expect(MeterMath.level(fromPower: .nan) == 0.0)
        #expect(MeterMath.level(fromPower: -.infinity) == 0.0)
    }
}
