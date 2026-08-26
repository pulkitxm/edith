import Foundation
import Testing
@testable import EdithKit

@Suite struct LoadingPrimitivesTests {
    @Test func contentStatesPreserveExistingGeometry() {
        #expect(ContentLoadingState.content.presentsContent)
        #expect(ContentLoadingState.refreshing.presentsContent)
        #expect(ContentLoadingState.partial.presentsContent)
        #expect(!ContentLoadingState.loading.presentsContent)
    }

    @Test func terminalStatesPermitRecovery() {
        for state in [
            ContentLoadingState.empty, .error, .offline, .cancelled,
        ] {
            #expect(state.permitsRetry)
        }
        #expect(!ContentLoadingState.loading.permitsRetry)
        #expect(!ContentLoadingState.content.permitsRetry)
    }

    @Test func skeletonAnimationHasOneOwner() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/EdithKit/UI/LoadingPrimitives.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let groupStart = try #require(source.range(of: "public struct SkeletonGroup"))
        let blockStart = try #require(source.range(of: "public struct SkeletonBlock"))
        let group = String(source[groupStart.lowerBound..<blockStart.lowerBound])
        let block = String(source[blockStart.lowerBound...])

        #expect(group.contains("repeatForever"))
        #expect(group.contains("guard !reduceMotion"))
        #expect(!block.contains("repeatForever"))
        #expect(!block.contains("@State"))
    }
}
