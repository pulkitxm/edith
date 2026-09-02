import Foundation
import Testing
@testable import EdithKit

@Suite struct LoadingPrimitivesTests {
    @Test func contentStatePreservesExistingGeometry() {
        #expect(ContentLoadingState.content.presentsContent)
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

    @Test func skeletonReplicasPreserveLayoutWithoutInteraction() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/EdithKit/UI/LoadingPrimitives.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let replicaStart = try #require(source.range(of: "public struct SkeletonReplica"))
        let blockStart = try #require(source.range(of: "public struct SkeletonBlock"))
        let replica = String(source[replicaStart.lowerBound..<blockStart.lowerBound])

        #expect(replica.contains("content.skeletonized()"))
        #expect(replica.components(separatedBy: "content.skeletonized()").count == 2)
        #expect(replica.contains(".redacted(reason: .placeholder)"))
        #expect(replica.contains(".disabled(true)"))
        #expect(replica.contains(".allowsHitTesting(false)"))
        #expect(replica.contains(".accessibilityHidden(true)"))
        #expect(replica.contains(".accessibilityLabel(label)"))
        #expect(!replica.contains("SkeletonGroup"))
        #expect(!replica.contains(".overlay"))
        #expect(!replica.contains("repeatForever"))
    }
}
