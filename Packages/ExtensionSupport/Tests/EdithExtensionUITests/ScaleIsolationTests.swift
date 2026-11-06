import EdithExtensionCore
import EdithExtensionTestSupport
import Foundation
import Testing

@testable import EdithExtensionUI

private struct SyntheticScaleFailure: Error {}

@MainActor @Suite(.serialized) struct ScaleIsolationTests {
    private static var storedZoom: Double? {
        (ExtensionScope.process.defaults().object(forKey: WindowZoom.defaultsKey) as? NSNumber)?
            .doubleValue
    }

    @Test func exclusiveScaleKeepsConcurrentHoldersFromInterleaving() async {
        var log: [String] = []
        await withTaskGroup(of: Void.self) { group in
            for name in ["first", "second", "third"] {
                group.addTask { @MainActor in
                    await RenderCapture.exclusiveScale {
                        log.append(name + " in")
                        try? await Task.sleep(for: .milliseconds(30))
                        await RenderCapture.exclusiveScale { await Task.yield() }
                        log.append(name + " out")
                    }
                }
            }
        }
        #expect(log.count == 6)
        for index in stride(from: 0, to: log.count, by: 2) {
            #expect(log[index].dropLast(3) == log[index + 1].dropLast(4))
        }
    }

    @Test func withScaleRestoresTheScaleAndStoredZoomEvenWhenItsBodyThrows() async {
        await RenderCapture.withScale(1) {
            let baselineZoom = Self.storedZoom
            await RenderCapture.withScale(1.6) {
                #expect(UIScale.current == 1.6)
                #expect(Self.storedZoom == 1.6)
                await RenderCapture.withScale(1.25) {
                    #expect(UIScale.current == 1.25)
                    #expect(Self.storedZoom == 1.25)
                }
                #expect(UIScale.current == 1.6)
                #expect(Self.storedZoom == 1.6)
            }
            #expect(UIScale.current == 1)
            await #expect(throws: SyntheticScaleFailure.self) {
                try await RenderCapture.withScale(1.4) { throw SyntheticScaleFailure() }
            }
            #expect(UIScale.current == 1)
            #expect(Self.storedZoom == baselineZoom)
        }
    }

    @Test func scopedTestsNeverObserveAnotherTestsScale() async throws {
        let test = try #require(Test.current)
        let trait = ExclusiveScaleTrait()
        var observed: [String: Set<Double>] = [:]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (name, zoom) in [("zoomed", 1.6), ("plain", 1.0), ("large", 1.25)] {
                group.addTask { @MainActor in
                    try await trait.provideScope(for: test, testCase: Test.Case.current) {
                        await MainActor.run {
                            observed[name, default: []].insert(UIScale.current)
                            UIScale.apply(zoom)
                        }
                        for _ in 0..<4 {
                            try await Task.sleep(for: .milliseconds(15))
                            await MainActor.run {
                                _ = observed[name, default: []].insert(UIScale.current)
                            }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(observed["zoomed"] == [1, 1.6])
        #expect(observed["plain"] == [1])
        #expect(observed["large"] == [1, 1.25])
    }
}
