import AppKit
import Testing
@testable import Edith

@MainActor
@Suite struct LimitsStatusItemTests {
    @Test func lowRiskIsPureGreen() {
        #expect(LimitsStatusItem.color(forRisk: 0.0) == .systemGreen)
        #expect(LimitsStatusItem.color(forRisk: 0.30) == .systemGreen)
    }

    @Test func highRiskIsPureRed() {
        #expect(LimitsStatusItem.color(forRisk: 0.85) == .systemRed)
        #expect(LimitsStatusItem.color(forRisk: 1.0) == .systemRed)
    }

    @Test func midRiskIsInterpolated() {
        let c = LimitsStatusItem.color(forRisk: 0.42)
        #expect(c != .systemGreen)
        #expect(c != .systemRed)
    }

    @Test func riskClamps() {
        #expect(LimitsStatusItem.color(forRisk: -1) == .systemGreen)
        #expect(LimitsStatusItem.color(forRisk: 2) == .systemRed)
    }
}
