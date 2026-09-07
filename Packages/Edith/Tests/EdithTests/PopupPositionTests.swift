import AppKit
import Testing

@testable import EdithKit

@MainActor
@Suite struct PopupPositionTests {
    private let positionKeys = ["clipboardWindowPositionX", "clipboardWindowPositionY"]

    private func selectedScreen(_ point: NSPoint, _ size: NSSize) -> NSScreen? {
        NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: point.x, y: point.y + size.height))
        }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
    }

    private func snapshotPositionKeys() -> [String: Any] {
        var snapshot: [String: Any] = [:]
        for key in positionKeys {
            snapshot[key] = SharedDefaults.store.object(forKey: key)
        }
        return snapshot
    }

    private func restorePositionKeys(_ snapshot: [String: Any]) {
        for key in positionKeys {
            if let value = snapshot[key] {
                SharedDefaults.store.set(value, forKey: key)
            } else {
                SharedDefaults.store.removeObject(forKey: key)
            }
        }
    }

    @Test func inBoundsPointIsUnchanged() throws {
        let size = NSSize(width: 100, height: 100)
        let visible = try #require(NSScreen.main).visibleFrame
        let point = NSPoint(x: visible.midX - 50, y: visible.midY - 50)
        #expect(PopupPosition.clampedToScreen(point, size) == point)
    }

    @Test func pointPastLeftEdgeClampsToVisibleMinX() throws {
        let size = NSSize(width: 200, height: 50)
        let globalMinX = try #require(NSScreen.screens.map(\.frame.minX).min())
        let point = NSPoint(x: globalMinX - 1000, y: 100)
        let visible = try #require(selectedScreen(point, size)).visibleFrame
        let result = PopupPosition.clampedToScreen(point, size)
        #expect(result.x == visible.minX)
        #expect(result.y >= visible.minY)
        #expect(result.y <= max(visible.minY, visible.maxY - size.height))
    }

    @Test func pointPastRightEdgeClampsToVisibleMaxXMinusWidth() throws {
        let size = NSSize(width: 200, height: 50)
        let globalMaxX = try #require(NSScreen.screens.map(\.frame.maxX).max())
        let point = NSPoint(x: globalMaxX + 1000, y: 100)
        let visible = try #require(selectedScreen(point, size)).visibleFrame
        let result = PopupPosition.clampedToScreen(point, size)
        #expect(result.x == max(visible.minX, visible.maxX - size.width))
        #expect(result.x < point.x)
    }

    @Test func pointPastBottomEdgeClampsToVisibleMinY() throws {
        let size = NSSize(width: 200, height: 50)
        let globalMinY = try #require(NSScreen.screens.map(\.frame.minY).min())
        let point = NSPoint(x: 100, y: globalMinY - 1000)
        let visible = try #require(selectedScreen(point, size)).visibleFrame
        let result = PopupPosition.clampedToScreen(point, size)
        #expect(result.y == visible.minY)
    }

    @Test func pointPastTopEdgeClampsToVisibleMaxYMinusHeight() throws {
        let size = NSSize(width: 200, height: 50)
        let globalMaxY = try #require(NSScreen.screens.map(\.frame.maxY).max())
        let point = NSPoint(x: 100, y: globalMaxY + 1000)
        let visible = try #require(selectedScreen(point, size)).visibleFrame
        let result = PopupPosition.clampedToScreen(point, size)
        #expect(result.y == max(visible.minY, visible.maxY - size.height))
        #expect(result.y < point.y)
    }

    @Test func popupLargerThanScreenAnchorsAtVisibleOrigin() throws {
        let frames = NSScreen.screens.map(\.frame)
        let totalWidth = try #require(frames.map(\.width).max())
        let totalHeight = try #require(frames.map(\.height).max())
        let size = NSSize(width: totalWidth + 1000, height: totalHeight + 1000)
        let point = NSPoint(x: 50, y: 50)
        let visible = try #require(selectedScreen(point, size)).visibleFrame
        let result = PopupPosition.clampedToScreen(point, size)
        #expect(result.x == visible.minX)
        #expect(result.y == visible.minY)
    }

    @Test func saveLastPositionStoresNormalizedRelativeCoordinates() throws {
        let snapshot = snapshotPositionKeys()
        defer { restorePositionKeys(snapshot) }
        let screen = try #require(NSScreen.main)
        let bounds = screen.frame
        let frame = NSRect(
            x: bounds.minX + bounds.width * 0.25, y: bounds.minY + bounds.height * 0.25,
            width: 300, height: 200)
        PopupPosition.saveLastPosition(frame: frame, screen: screen, anchors: .clipboard)
        let store = SharedDefaults.store
        let relX = try #require(store.object(forKey: "clipboardWindowPositionX") as? Double)
        let relY = try #require(store.object(forKey: "clipboardWindowPositionY") as? Double)
        #expect(abs(relX - Double((frame.midX - bounds.minX) / bounds.width)) < 0.0001)
        #expect(abs(relY - Double((frame.maxY - bounds.minY) / bounds.height)) < 0.0001)
        #expect(relX >= 0 && relX <= 1)
        #expect(relY >= 0 && relY <= 1)
    }

    @Test func savedFrameRoundTripsThroughLastPositionOrigin() async throws {
        let snapshot = snapshotPositionKeys()
        defer { restorePositionKeys(snapshot) }
        let size = NSSize(width: 300, height: 200)
        let mouse = NSEvent.mouseLocation
        let screen = try #require(
            NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
            width: size.width, height: size.height)
        PopupPosition.saveLastPosition(frame: frame, screen: screen, anchors: .clipboard)
        let origin = await PopupPosition.lastPosition.origin(
            size: size, statusItemFrame: nil, anchors: .clipboard)
        #expect(abs(origin.x - frame.minX) < 0.5)
        #expect(abs(origin.y - frame.minY) < 0.5)
    }

    @Test func saveLastPositionWithoutScreenWritesNothing() {
        let snapshot = snapshotPositionKeys()
        defer { restorePositionKeys(snapshot) }
        let store = SharedDefaults.store
        for key in positionKeys { store.removeObject(forKey: key) }
        PopupPosition.saveLastPosition(
            frame: NSRect(x: 10, y: 10, width: 100, height: 100), screen: nil, anchors: .clipboard)
        #expect(store.object(forKey: "clipboardWindowPositionX") == nil)
        #expect(store.object(forKey: "clipboardWindowPositionY") == nil)
    }
}
