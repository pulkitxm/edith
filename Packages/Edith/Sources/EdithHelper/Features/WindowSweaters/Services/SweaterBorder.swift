import CoreGraphics
import EdithKit
import Foundation

@MainActor
final class SweaterBorder {
    static let padding = 8.0

    let connection: SkyLight.Connection
    let targetWindow: SkyLight.WindowID

    var app = ""
    var focused = false
    var radius = 9.0
    var innerRadius = 10.0
    var space: SkyLight.SpaceID = 0

    private(set) var visible = false
    var needsRedraw = true
    var metadataDirty = true
    var geometryValid = false
    var nativeTransform = false
    var resizeSuppressed = false
    var tooSmall = false
    var sticky = false
    var opacity = 1.0
    var targetBounds = CGRect.zero
    var missingSnapshots = 0
    var missingOverlaySnapshots = 0
    var overlayRebuildAfter = 0.0
    var spaceCheckAfter = 0.0

    private var overlayWindow: SkyLight.WindowID = 0
    private var context: CGContext?
    private var origin = CGPoint.zero
    private var frame = CGRect.zero
    private var drawingBounds = CGRect.zero
    private var level: Int32 = 0
    private var subLevel: Int32 = 0
    private var resizeObservedSize = CGSize.zero
    private var resizeSettleAfter = 0.0

    var overlayIdentifier: SkyLight.WindowID { overlayWindow }

    init(target: SkyLight.WindowID) {
        connection = SweaterWindowServer.newConnection()
        targetWindow = target
    }

    func tearDown() {
        hide()
        destroyOverlay()
        SweaterWindowServer.releaseConnection(connection)
    }

    private func destroyOverlay() {
        context = nil
        if overlayWindow != 0 { _ = SkyLight.releaseWindow?(connection, overlayWindow) }
        overlayWindow = 0
    }

    func resetSurface() {
        destroyOverlay()
        visible = false
        geometryValid = false
        metadataDirty = true
        needsRedraw = true
        opacity = 1
    }

    func update(settings: SweaterRuntimeSettings) {
        guard let bounds = observedBounds() else {
            hide()
            return
        }
        guard !suppressLiveResize(bounds: bounds, settings: settings) else {
            hide()
            return
        }
        updateInternal(settings: settings, observed: bounds)
        apply(opacity: opacity)
    }

    func updateGeometry(settings: SweaterRuntimeSettings) {
        guard let bounds = observedBounds() else {
            hide()
            return
        }
        updateGeometry(settings: settings, bounds: bounds, opacity: opacity)
    }

    func updateGeometry(settings: SweaterRuntimeSettings, bounds: CGRect, opacity: Double) {
        applyGeometry(settings: settings, bounds: bounds)
        apply(opacity: opacity)
    }

    private func observedBounds() -> CGRect? {
        guard !nativeTransform else { return nil }
        return SweaterWindowServer.bounds(of: targetWindow, connection: connection)
    }

    func suppressLiveResize(bounds: CGRect, settings: SweaterRuntimeSettings) -> Bool {
        guard settings.active else { return false }
        if !resizeSuppressed, !visible || bounds.size == drawingBounds.size { return false }
        let held = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let now = CFAbsoluteTimeGetCurrent()
        if !resizeSuppressed || held || bounds.size != resizeObservedSize {
            resizeObservedSize = bounds.size
            resizeSettleAfter = now + 0.06
        }
        if !held, now >= resizeSettleAfter {
            resizeSuppressed = false
            return false
        }
        resizeSuppressed = true
        if visible { hide() }
        return true
    }

    private func applyGeometry(settings: SweaterRuntimeSettings, bounds: CGRect) {
        guard !suppressLiveResize(bounds: bounds, settings: settings) else { return }
        guard geometryValid, overlayWindow != 0, context != nil, !needsRedraw, !tooSmall,
            !metadataDirty, bounds.origin.x.isFinite, bounds.origin.y.isFinite,
            bounds.size == drawingBounds.size
        else {
            updateInternal(settings: settings, observed: bounds)
            return
        }
        guard bounds != targetBounds else { return }

        let inset = settings.borderWidth + Self.padding
        let moved = CGPoint(x: bounds.origin.x - inset, y: bounds.origin.y - inset)
        let committed = SweaterWindowServer.withTransaction(connection: connection) { transaction in
            _ = SkyLight.transactionMoveWindowWithGroup?(transaction, overlayWindow, moved)
            _ = SkyLight.transactionOrderWindow?(
                transaction, overlayWindow, settings.order, targetWindow)
        }
        if committed {
            targetBounds = bounds
            origin = moved
        }
    }

    private func calculateBounds(settings: SweaterRuntimeSettings, observed: CGRect) -> CGRect? {
        guard observed.origin.x.isFinite, observed.origin.y.isFinite,
            observed.size.width.isFinite, observed.size.height.isFinite,
            observed.size.width > 0, observed.size.height > 0
        else {
            hide()
            return nil
        }
        targetBounds = observed

        let smallest = observed.insetBy(dx: 1, dy: 1)
        tooSmall =
            smallest.size.width < 2 * innerRadius || smallest.size.height < 2 * innerRadius
        if tooSmall {
            hide()
            return nil
        }

        let offset = -settings.borderWidth - Self.padding
        var frame = observed.insetBy(dx: offset, dy: offset)
        origin = frame.origin
        frame.origin = .zero
        drawingBounds = CGRect(
            x: -offset, y: -offset, width: observed.size.width, height: observed.size.height)
        return frame
    }

    private func updateInternal(settings: SweaterRuntimeSettings, observed: CGRect) {
        guard !resizeSuppressed else { return }
        geometryValid = false
        guard let frame = calculateBounds(settings: settings, observed: observed) else { return }

        if metadataDirty {
            let tags = SweaterWindowServer.tags(of: targetWindow, connection: connection)
            sticky = tags & SweaterWindowTag.sticky != 0
            level = SweaterWindowServer.level(of: targetWindow, connection: connection)
            subLevel = SweaterWindowServer.subLevel(of: targetWindow, connection: connection)
            let current = SweaterWindowServer.space(of: targetWindow, connection: connection)
            if current != 0, current != space {
                space = current
                if overlayWindow != 0 {
                    SweaterWindowServer.send(overlayWindow, to: current, connection: connection)
                }
            }
            metadataDirty = false
        }
        guard sticky || SweaterWindowServer.isSpaceVisible(space, connection: connection)
        else { return }
        guard SweaterWindowServer.isOrderedIn(targetWindow, connection: connection) == true
        else {
            hide()
            return
        }

        if overlayWindow == 0 { createOverlay(frame: frame, hidpi: settings.hidpi) }
        guard overlayWindow != 0, context != nil else { return }
        if frame != self.frame { needsRedraw = true }

        guard let transaction = SkyLight.transactionCreate?(connection)?.takeRetainedValue()
        else { return }

        var disabledUpdate = false
        if frame != self.frame {
            guard let region = SkyLightSupport.region(for: frame) else { return }
            defer { SkyLight.release(region) }
            disabledUpdate = true
            _ = SkyLight.disableUpdate?(connection)
            _ = SkyLight.windowFreeze?(connection, overlayWindow, nil)
            let shaped = SkyLight.setWindowShape?(
                connection, overlayWindow, Float(origin.x), Float(origin.y), region)
            guard shaped == .success else {
                _ = SkyLight.windowThaw?(connection, overlayWindow)
                _ = SkyLight.reenableUpdate?(connection)
                return
            }
            guard
                let rebound = SkyLight.windowContextCreate?(connection, overlayWindow, nil)?
                    .takeRetainedValue()
            else {
                _ = SkyLight.windowThaw?(connection, overlayWindow)
                _ = SkyLight.reenableUpdate?(connection)
                return
            }
            rebound.interpolationQuality = .none
            context = rebound
            needsRedraw = true
            self.frame = frame
        }

        if needsRedraw { draw(frame: frame, settings: settings) }

        _ = SkyLight.transactionMoveWindowWithGroup?(transaction, overlayWindow, origin)
        var transform = CGAffineTransform.identity
        transform.tx = -origin.x
        transform.ty = -origin.y
        _ = SkyLight.transactionSetWindowTransform?(transaction, overlayWindow, 0, 0, transform)
        _ = SkyLight.transactionSetWindowLevel?(transaction, overlayWindow, level)
        _ = SkyLight.transactionSetWindowSubLevel?(transaction, overlayWindow, subLevel)
        _ = SkyLight.transactionOrderWindow?(
            transaction, overlayWindow, settings.order, targetWindow)
        _ = SkyLight.transactionCommit?(transaction, 0)

        var setTags: UInt64 = SweaterWindowTag.floating | (1 << 9)
        var clearTags: UInt64 = 0
        if sticky {
            setTags |= SweaterWindowTag.sticky
            clearTags |= 1 << 45
        } else {
            clearTags |= SweaterWindowTag.sticky
        }
        _ = SkyLight.setWindowTags?(connection, overlayWindow, &setTags, 64)
        _ = SkyLight.clearWindowTags?(connection, overlayWindow, &clearTags, 64)

        if disabledUpdate { _ = SkyLight.reenableUpdate?(connection) }
        geometryValid = true
        visible = true
    }

    private func createOverlay(frame: CGRect, hidpi: Bool) {
        overlayWindow = SweaterWindowServer.createOverlay(
            frame: frame, hidpi: hidpi, connection: connection)
        guard overlayWindow != 0 else { return }
        opacity = 1
        self.frame = frame
        needsRedraw = true
        guard
            let created = SkyLight.windowContextCreate?(connection, overlayWindow, nil)?
                .takeRetainedValue()
        else {
            destroyOverlay()
            return
        }
        created.interpolationQuality = .none
        context = created
        if space == 0 {
            space = SweaterWindowServer.space(of: targetWindow, connection: connection)
        }
        SweaterWindowServer.send(overlayWindow, to: space, connection: connection)
    }

    private func draw(frame: CGRect, settings: SweaterRuntimeSettings) {
        guard let context else { return }
        needsRedraw = false
        context.saveGState()
        context.clear(frame)
        defer {
            context.flush()
            context.restoreGState()
            _ = SkyLight.flushWindowContentRegion?(connection, overlayWindow, nil)
            _ = SkyLight.windowThaw?(connection, overlayWindow)
        }
        guard settings.active else { return }

        let yarn = settings.yarn(forApp: app)
        settings.renderer.draw(
            in: context, windowRect: drawingBounds, radius: radius, band: settings.borderWidth,
            color: yarn.color, chart: yarn.chart, dim: focused ? 0 : settings.unfocusedDim,
            tuck: settings.order == SweaterOrdering.above ? 1 : settings.tuck,
            stitch: settings.stitch,
            anchor: settings.anchor, gauge: settings.gauge)
    }

    func refreshSpace() {
        guard !sticky else { return }
        let current = SweaterWindowServer.space(of: targetWindow, connection: connection)
        guard current != 0 else { return }
        let overlaySpace =
            overlayWindow != 0
            ? SweaterWindowServer.space(of: overlayWindow, connection: connection) : current
        guard current != space || overlaySpace != current else { return }
        if overlayWindow != 0 {
            SweaterWindowServer.send(overlayWindow, to: current, connection: connection)
        }
        space = current
        metadataDirty = true
        geometryValid = false
        needsRedraw = true
    }

    func apply(opacity value: Double) {
        guard value.isFinite, overlayWindow != 0 else { return }
        let clamped = min(max(value, 0), 1)
        guard abs(opacity - clamped) > 0.001 else { return }
        guard SkyLight.setWindowAlpha?(connection, overlayWindow, Float(clamped)) == .success
        else { return }
        opacity = clamped
    }

    func reorder(settings: SweaterRuntimeSettings) {
        guard !resizeSuppressed, overlayWindow != 0, context != nil, !tooSmall,
            sticky || SweaterWindowServer.isSpaceVisible(space, connection: connection)
        else { return }
        guard SweaterWindowServer.isOrderedIn(targetWindow, connection: connection) == true
        else {
            hide()
            return
        }
        guard SweaterWindowServer.isOrderedIn(overlayWindow, connection: connection) == true
        else { return }
        let currentLevel = SweaterWindowServer.level(of: targetWindow, connection: connection)
        let currentSubLevel = SweaterWindowServer.subLevel(
            of: targetWindow, connection: connection)
        let committed = SweaterWindowServer.withTransaction(connection: connection) { transaction in
            _ = SkyLight.transactionSetWindowLevel?(transaction, overlayWindow, currentLevel)
            _ = SkyLight.transactionSetWindowSubLevel?(
                transaction, overlayWindow, currentSubLevel)
            _ = SkyLight.transactionOrderWindow?(
                transaction, overlayWindow, settings.order, targetWindow)
        }
        if committed {
            level = currentLevel
            subLevel = currentSubLevel
        }
    }

    func hide() {
        geometryValid = false
        visible = false
        guard overlayWindow != 0 else { return }
        _ = SweaterWindowServer.withTransaction(connection: connection) { transaction in
            _ = SkyLight.transactionOrderWindow?(transaction, overlayWindow, 0, targetWindow)
        }
    }

    func unhide(settings: SweaterRuntimeSettings) {
        guard !resizeSuppressed, !nativeTransform, !tooSmall, overlayWindow != 0,
            sticky || SweaterWindowServer.isSpaceVisible(space, connection: connection)
        else { return }
        let committed = SweaterWindowServer.withTransaction(connection: connection) { transaction in
            _ = SkyLight.transactionOrderWindow?(
                transaction, overlayWindow, settings.order, targetWindow)
        }
        if committed { visible = true }
    }
}
