import Foundation
import Testing
@testable import EdithStudio

@Suite struct StudioInertEnvironmentTests {
    @Test func explicitEmptyResolverNeverFallsBackToSearchPathsOrSystemAvailability() throws {
        let environment = StudioEnvironment.detect(path: "/fixture-toolbin",
            resolve: { _ in nil }, allowsSearchFallback: false, modelAvailable: { false },
            translationAvailable: false)
        #expect(environment.ffmpeg == nil)
        #expect(environment.ffprobe == nil)
        #expect(environment.qpdf == nil)
        #expect(!environment.appleIntelligenceAvailable)
        #expect(!environment.satisfies(.translation))
        #expect(throws: (any Error).self) { try environment.require(.ffmpeg) }
    }

    @Test func explicitSyntheticResolverSuppliesOnlyItsOwnToolAndAvailability() {
        let stub = URL(fileURLWithPath: "/synthetic-unit-toolbin/qpdf")
        let environment = StudioEnvironment.detect(path: "",
            resolve: { $0 == "qpdf" ? stub : nil }, allowsSearchFallback: false,
            modelAvailable: { false }, translationAvailable: false)
        #expect(environment.qpdf == stub)
        #expect(environment.ffmpeg == nil)
        #expect(environment.ffprobe == nil)
        #expect(!environment.appleIntelligenceAvailable)
    }
}
