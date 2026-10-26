import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@MainActor
struct HostUIResourceOwnersTests {
    @Test func closingOneWindowKeepsSharedResourcesUntilTheLastOwnerReleases() throws {
        let owners = HostUIResourceOwners()
        let first = UUID(), second = UUID()
        try owners.acquire(first)
        try owners.acquire(second)
        let firstRuntime = NSObject(), secondRuntime = NSObject()
        ExtensionUIResources.bind(owners.bridge(for: first), to: firstRuntime)
        ExtensionUIResources.bind(owners.bridge(for: second), to: secondRuntime)
        var cleanupCount = 0
        #expect(!ExtensionUIResources.canDrainSharedResources(of: firstRuntime))
        #expect(!owners.beginExclusiveClose(first))
        ExtensionUIResources.cleanup(of: firstRuntime, key: "terminal") { cleanupCount += 1 }
        owners.release(first)
        #expect(cleanupCount == 0)
        #expect(ExtensionUIResources.canDrainSharedResources(of: secondRuntime))
        owners.release(second)
        #expect(cleanupCount == 1)
    }

    @Test func cleanupFromAnEarlierWindowCannotStopAReplacementWindow() throws {
        let owners = HostUIResourceOwners()
        let first = UUID(), second = UUID(), replacement = UUID()
        try owners.acquire(first)
        try owners.acquire(second)
        let runtime = NSObject()
        ExtensionUIResources.bind(owners.bridge(for: first), to: runtime)
        owners.release(first)
        try owners.acquire(replacement)
        var cleaned = false
        ExtensionUIResources.cleanup(of: runtime, key: "late") { cleaned = true }
        owners.release(second)
        #expect(!cleaned)
        owners.release(replacement)
        #expect(cleaned)
    }

    @Test func finalCleanupReplacesDeferredCleanupButPreservesSeparateImages() throws {
        let owners = HostUIResourceOwners()
        let first = UUID(), second = UUID()
        try owners.acquire(first)
        try owners.acquire(second)
        let firstApp = NSObject(), firstHelper = NSObject(), secondApp = NSObject()
        ExtensionUIResources.bind(owners.bridge(for: first), to: firstApp)
        ExtensionUIResources.bind(owners.bridge(for: first, scope: "helper"), to: firstHelper)
        ExtensionUIResources.bind(owners.bridge(for: second), to: secondApp)
        var result: [String] = []
        ExtensionUIResources.cleanup(of: firstApp, key: "editor") { result.append("stale") }
        ExtensionUIResources.cleanup(of: firstHelper, key: "editor") { result.append("helper") }
        owners.release(first)
        ExtensionUIResources.cleanup(of: secondApp, key: "editor") { result.append("app") }
        owners.release(second)
        #expect(result == ["app", "helper"])
    }

    @Test func finalPreparationBlocksNewPresentationsOnlyWhileItDrains() throws {
        let owners = HostUIResourceOwners()
        let current = UUID(), replacement = UUID()
        try owners.acquire(current)
        #expect(owners.beginExclusiveClose(current))
        #expect(throws: HostWorkerError.rejected) { try owners.acquire(replacement) }
        owners.endExclusiveClose(current)
        try owners.acquire(replacement)
        #expect(!owners.beginExclusiveClose(current))
        owners.release(current)
        owners.release(replacement)
    }

    @Test func engineAndStandaloneResourcesCleanUpImmediately() {
        let runtime = NSObject()
        var cleaned = false
        ExtensionUIResources.cleanup(of: runtime, key: "engine") { cleaned = true }
        #expect(cleaned)
        #expect(ExtensionUIResources.canDrainSharedResources(of: runtime))
    }
}
