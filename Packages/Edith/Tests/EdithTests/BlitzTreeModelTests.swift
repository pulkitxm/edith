import Foundation
import Testing

@testable import Edith
@testable import EdithKit

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
}

private actor ScanGate {
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
