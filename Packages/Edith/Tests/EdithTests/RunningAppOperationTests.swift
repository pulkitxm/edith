import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct RunningAppOperationTests {
    static let finder = RunningAppSnapshot(
        pid: 1, name: "Finder", bundleID: "com.apple.finder", active: false)
    static let safari = RunningAppSnapshot(
        pid: 2, name: "Safari", bundleID: "com.apple.Safari", active: true)
    static let safariTechnologyPreview = RunningAppSnapshot(
        pid: 3, name: "Safari Technology Preview",
        bundleID: "com.apple.SafariTechnologyPreview", active: false)
    static let music = RunningAppSnapshot(
        pid: 4, name: "Music", bundleID: "com.apple.Music", active: false)

    @Test func descriptorsAreRegisteredAndReachRealLeaves() {
        for operation in RunningAppOperation.allCases {
            let descriptor = operation.descriptor
            #expect(UserOperationCatalog.descriptor(id: descriptor.id) == descriptor)
            let node = descriptor.cli.reduce(Optional(CommandTree.root)) { node, component in
                node?.child(component)
            }
            #expect(node?.children.isEmpty == true)
        }
        #expect(RunningAppOperation.quit.descriptor.requiresPreview)
        #expect(RunningAppOperation.quit.descriptor.effect == .destructive)
    }

    @Test func listAndCompletionUseTheSameSortedSnapshots() {
        let center = RunningAppOperationCenter(snapshot: { [Self.music, Self.safari] })

        #expect(center.list().map(\.name) == ["Music", "Safari"])
        #expect(
            center.completionValues()
                == ["Music", "com.apple.Music", "Safari", "com.apple.Safari"])
    }

    @Test func resolutionSupportsExactNamesBundleIDsAndUniquePrefixes() throws {
        let center = RunningAppOperationCenter(snapshot: { [Self.safari, Self.music] })

        #expect(try center.plan(.query("safari")).targets == [Self.safari])
        #expect(try center.plan(.query("COM.APPLE.MUSIC")).targets == [Self.music])
        #expect(try center.plan(.query("mus")).targets == [Self.music])
    }

    @Test func ambiguousAndMissingQueriesAreExplicit() {
        let center = RunningAppOperationCenter(
            snapshot: { [Self.safari, Self.safariTechnologyPreview] })

        #expect(
            throws: RunningAppResolutionError.ambiguous(
                "Saf", ["Safari", "Safari Technology Preview"])
        ) {
            try center.plan(.query("Saf"))
        }
        #expect(throws: RunningAppResolutionError.notFound("Music")) {
            try center.plan(.query("Music"))
        }
    }

    @Test func protectedAppsCannotBecomeNamedTargetsAndAreExcludedFromAll() throws {
        let center = RunningAppOperationCenter(snapshot: { [Self.finder, Self.safari] })

        #expect(throws: RunningAppResolutionError.protected("Finder")) {
            try center.plan(.query("Finder"))
        }
        #expect(try center.plan(.all).targets == [Self.safari])
    }

    @Test func previewDoesNotInvokeThePerformer() throws {
        final class Capture {
            var calls = 0
        }
        let capture = Capture()
        let center = RunningAppOperationCenter(
            snapshot: { [Self.safari] },
            perform: { targets, _ in
                capture.calls += 1
                return targets.count
            })
        let plan = try center.plan(.query("Safari"))

        let outcome = center.apply(plan, confirmed: false)

        #expect(outcome.applied == false)
        #expect(outcome.changed == 0)
        #expect(capture.calls == 0)
    }

    @Test func confirmedExecutionReceivesOnlyThePlannedTargets() throws {
        final class Capture {
            var targets: [RunningAppSnapshot] = []
            var force = false
        }
        let capture = Capture()
        let center = RunningAppOperationCenter(
            snapshot: { [Self.finder, Self.safari, Self.music] },
            perform: { targets, force in
                capture.targets = targets
                capture.force = force
                return targets.count
            })
        let plan = try center.plan(.all, force: true)

        let outcome = center.apply(plan, confirmed: true)

        #expect(capture.targets == [Self.music, Self.safari])
        #expect(capture.force)
        #expect(outcome.applied)
        #expect(outcome.changed == 2)
    }
}
