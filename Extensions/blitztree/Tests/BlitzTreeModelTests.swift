import Foundation
import Testing
@testable import BlitzTreeExtension

@MainActor @Suite struct BlitzTreeModelTests {
    @Test func cancelledScanCannotReplaceANewerResult() async throws {
        let gate = ScanGate()
        let model = BlitzTreeModel(
            client: BlitzTreeClient { root, _ in
                if root == "/old" { await gate.wait() }
                return BlitzTreeClientTests.report(root: root)
            })
        model.scan("/old")
        while !(await gate.waiting) { await Task.yield() }
        model.scan("/new")
        while model.scanning { await Task.yield() }
        #expect(model.report?.root == "/new")
        await gate.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(model.report?.root == "/new")
        #expect(model.error == nil)
        #expect(model.history == ["/old"])
    }

    @Test func backAndCancelPreserveNavigation() async {
        let model = BlitzTreeModel(
            client: BlitzTreeClient { root, _ in
                BlitzTreeClientTests.report(root: root)
            })
        model.scan("/parent")
        while model.scanning { await Task.yield() }
        model.scan("/parent/child")
        while model.scanning { await Task.yield() }
        model.back()
        while model.scanning { await Task.yield() }
        #expect(model.root == "/parent")
        #expect(model.history.isEmpty)
        model.scan("/cancelled")
        model.cancel()
        await Task.yield()
        #expect(!model.scanning)
        #expect(model.report == nil)
        #expect(model.error == nil)
    }

    @Test func idleModelPollsRarelyAndWorkingModelFollowsClosely() async {
        let model = BlitzTreeModel(
            client: BlitzTreeClient { root, _ in
                try await Task.sleep(for: .seconds(30))
                return BlitzTreeClientTests.report(root: root)
            })
        #expect(model.refreshInterval == .seconds(10))
        model.scan("/slow")
        #expect(model.scanning)
        #expect(model.refreshInterval == .seconds(1))
        model.cancel()
        await Task.yield()
        #expect(model.refreshInterval == .seconds(10))
    }
}

actor ScanGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite struct BlitzTreePresentationTests {
    @Test func noFolderYetShowsTheIntroduction() {
        #expect(
            BlitzTreePresentation(
                hasRoot: false, hasReport: false, scanning: false, hasError: false)
                == .intro)
    }

    @Test func scanningWithoutAReportShowsProgress() {
        #expect(
            BlitzTreePresentation(hasRoot: true, hasReport: false, scanning: true, hasError: false)
                == .scanning)
    }

    @Test func failedAndCancelledScansExplainThemselves() {
        #expect(
            BlitzTreePresentation(hasRoot: true, hasReport: false, scanning: false, hasError: true)
                == .failed)
        #expect(
            BlitzTreePresentation(hasRoot: true, hasReport: false, scanning: false, hasError: false)
                == .cancelled)
    }

    @Test func aReportKeepsShowingWhileRefreshingOrFailing() {
        #expect(
            BlitzTreePresentation(hasRoot: true, hasReport: true, scanning: true, hasError: true)
                == .results)
    }
}
