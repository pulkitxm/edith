import Foundation
import Testing

@testable import Edith
@testable import EdithKit

private final class FakeScrollChannel: HerdrScrollChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<HerdrScrollInfo, Error>.Continuation?
    private var targets: [Int] = []
    private(set) var closed = false

    func updates() -> AsyncThrowingStream<HerdrScrollInfo, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func send(_ info: HerdrScrollInfo) {
        _ = lock.withLock { continuation }?.yield(info)
    }

    var sent: [Int] { lock.withLock { targets } }

    var subscribed: Bool { lock.withLock { continuation != nil } }

    func scroll(to offset: Int) async throws -> HerdrScrollInfo? {
        lock.withLock { targets.append(offset) }
        return nil
    }

    func close() {
        lock.withLock {
            closed = true
            continuation?.finish()
        }
    }
}

@MainActor
@Suite struct HerdrTerminalScrollTests {
    @Test func paneInfoAndScrollEventsBothCarryTheScrollPosition() throws {
        let get = """
            {"id":"g","result":{"type":"pane_info","pane":{"pane_id":"w5:p4","scroll":{"offset_from_bottom":15,"max_offset_from_bottom":192,"viewport_rows":10}}}}
            """
        let event = """
            {"data":{"pane_id":"w5:p4","scroll":{"max_offset_from_bottom":192,"offset_from_bottom":40,"viewport_rows":10},"workspace_id":"w5"},"event":"pane.scroll_changed"}
            """
        #expect(
            HerdrListParser.scrollInfo(from: get, pane: "w5:p4")
                == HerdrScrollInfo(offset: 15, maximum: 192, viewportRows: 10))
        #expect(HerdrListParser.scrollInfo(from: event, pane: "w5:p4")?.offset == 40)
        #expect(HerdrListParser.scrollInfo(from: event, pane: "w5:p9") == nil)
        #expect(HerdrListParser.scrollInfo(from: "{}") == nil)
    }

    @Test func theThumbSizesToTheViewportAndSitsAtTheBottomWhenFollowing() {
        let info = HerdrScrollInfo(offset: 0, maximum: 90, viewportRows: 10)
        #expect(HerdrScrollbarGeometry.thumbLength(for: info, track: 400) == 40)
        #expect(HerdrScrollbarGeometry.thumbTop(for: info, track: 400) == 360)

        var top = info
        top.offset = 90
        #expect(HerdrScrollbarGeometry.thumbTop(for: top, track: 400) == 0)

        let long = HerdrScrollInfo(offset: 0, maximum: 100_000, viewportRows: 10)
        #expect(
            HerdrScrollbarGeometry.thumbLength(for: long, track: 400)
                == HerdrScrollbarGeometry.minimumThumb)
    }

    @Test func draggingTheThumbMapsBackToAnOffset() {
        let info = HerdrScrollInfo(offset: 0, maximum: 90, viewportRows: 10)
        #expect(HerdrScrollbarGeometry.offset(forThumbTop: 0, info: info, track: 400) == 90)
        #expect(HerdrScrollbarGeometry.offset(forThumbTop: 180, info: info, track: 400) == 45)
        #expect(HerdrScrollbarGeometry.offset(forThumbTop: 900, info: info, track: 400) == 0)
        #expect(HerdrScrollbarGeometry.offset(forThumbTop: -50, info: info, track: 400) == 90)
    }

    @Test func theModelFollowsHerdrAndSendsDragsBack() async throws {
        let channel = FakeScrollChannel()
        let scroll = HerdrTerminalScroll(retryDelay: .milliseconds(10)) { _, _, _ in channel }
        let watcher = Task { await scroll.watch(session: "default", pane: "w1:p1", machine: nil) }
        try await eventually { channel.subscribed }

        channel.send(HerdrScrollInfo(offset: 0, maximum: 50, viewportRows: 12))
        try await eventually { scroll.info?.maximum == 50 }

        scroll.scroll(to: 80)
        #expect(scroll.info?.offset == 50)
        try await eventually { channel.sent == [50] }

        channel.send(HerdrScrollInfo(offset: 20, maximum: 50, viewportRows: 12))
        try await eventually { scroll.info?.offset == 20 }

        scroll.scroll(to: 20)
        #expect(channel.sent == [50])

        watcher.cancel()
        channel.close()
        try await eventually { channel.closed }
    }

    @Test func aTerminalWithoutHistoryHasNothingToScroll() {
        let scroll = HerdrTerminalScroll { _, _, _ in FakeScrollChannel() }
        scroll.scroll(to: 10)
        #expect(scroll.info == nil)
        #expect(!HerdrScrollInfo(offset: 0, maximum: 0, viewportRows: 30).scrollable)
    }

    private func eventually(
        _ condition: @MainActor () async -> Bool, timeout: Duration = .seconds(3)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition was not met in time")
    }
}
