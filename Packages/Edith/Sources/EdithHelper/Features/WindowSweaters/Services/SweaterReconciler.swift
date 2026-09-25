import CoreGraphics
import Foundation

struct SweaterObservedWindow {
    var window: SkyLight.WindowID
    var pid: pid_t
    var bounds: CGRect
    var alpha: Double
    var layer: Int
    var rank: Int
    var previousForeign: Int
    var nextForeign: Int
    var justCreated = false
    var tracked = false
}

struct SweaterSnapshotResult {
    var windows: [SweaterObservedWindow]
    var liveWindows: Set<SkyLight.WindowID>?
}

enum SweaterSnapshot {
    static func capture(ownPID: pid_t, includingLiveness liveness: Bool)
        -> SweaterSnapshotResult
    {
        SweaterSnapshotResult(
            windows: onScreenWindows(ownPID: ownPID),
            liveWindows: liveness ? allWindowIdentifiers() : nil)
    }

    static func allWindowIdentifiers() -> Set<SkyLight.WindowID> {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var identifiers: Set<SkyLight.WindowID> = []
        identifiers.reserveCapacity(raw.count)
        for info in raw {
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            identifiers.insert(number.uint32Value)
        }
        return identifiers
    }

    static func onScreenWindows(ownPID: pid_t) -> [SweaterObservedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var observed: [SweaterObservedWindow] = []
        observed.reserveCapacity(raw.count)
        for (rank, info) in raw.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            observed.append(
                SweaterObservedWindow(
                    window: number.uint32Value, pid: pid.int32Value, bounds: bounds, alpha: alpha,
                    layer: layer, rank: rank, previousForeign: -1, nextForeign: raw.count))
        }

        var previousForeign = -1
        for index in observed.indices {
            observed[index].previousForeign = previousForeign
            if observed[index].pid != ownPID, observed[index].alpha > 0 {
                previousForeign = observed[index].rank
            }
        }
        var nextForeign = raw.count
        for index in observed.indices.reversed() {
            observed[index].nextForeign = nextForeign
            if observed[index].pid != ownPID, observed[index].alpha > 0 {
                nextForeign = observed[index].rank
            }
        }
        return observed
    }
}

@MainActor
final class SweaterReconciler {
    private static let interval = 0.05
    private static let livenessInterval = 0.25
    private static let settleInterval = 1.0

    private unowned let tracker: SweaterWindowTracker
    private var task: Task<Void, Never>?
    private var idleWait: Task<Void, Never>?
    private var hotUntil = 0.0
    private var previous: [SkyLight.WindowID: SweaterObservedWindow] = [:]
    private var liveWindows: Set<SkyLight.WindowID> = []
    private var liveWindowsExpiry = 0.0
    private let ownPID = getpid()

    init(tracker: SweaterWindowTracker) {
        self.tracker = tracker
    }

    func wake() {
        hotUntil = CFAbsoluteTimeGetCurrent() + Self.settleInterval
        idleWait?.cancel()
    }

    func start() {
        guard task == nil else { return }
        hotUntil = CFAbsoluteTimeGetCurrent() + Self.settleInterval
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let active = self.tracker.settings.active
                if active {
                    let pid = self.ownPID
                    let liveness = CFAbsoluteTimeGetCurrent() >= self.liveWindowsExpiry
                    let snapshot = await Task.detached(priority: .userInitiated) {
                        SweaterSnapshot.capture(ownPID: pid, includingLiveness: liveness)
                    }.value
                    guard !Task.isCancelled else { return }
                    if let live = snapshot.liveWindows {
                        self.liveWindows = live
                        self.liveWindowsExpiry =
                            CFAbsoluteTimeGetCurrent() + Self.livenessInterval
                    }
                    if self.reconcile(snapshot.windows) {
                        self.hotUntil = CFAbsoluteTimeGetCurrent() + Self.settleInterval
                    }
                }
                if active, CFAbsoluteTimeGetCurrent() < self.hotUntil {
                    try? await Task.sleep(for: .seconds(Self.interval))
                } else {
                    let wait = Task {
                        _ = try? await Task.sleep(
                            for: active ? .milliseconds(100) : .seconds(30),
                            tolerance: .milliseconds(active ? 10 : 1_000))
                    }
                    self.idleWait = wait
                    await wait.value
                    self.idleWait = nil
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        idleWait?.cancel()
        idleWait = nil
        previous.removeAll()
        liveWindows.removeAll()
        liveWindowsExpiry = 0
    }

    private func windowExists(_ window: SkyLight.WindowID) -> Bool {
        liveWindows.isEmpty || liveWindows.contains(window)
    }

    @discardableResult
    private func reconcile(_ snapshot: [SweaterObservedWindow]) -> Bool {
        guard !snapshot.isEmpty else { return false }
        let moved =
            snapshot.contains { entry in
                guard let before = previous[entry.window] else { return true }
                return before.bounds != entry.bounds || before.alpha != entry.alpha
            } || snapshot.count != previous.count
        let now = CFAbsoluteTimeGetCurrent()
        let settings = tracker.settings
        var observed = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.window, $0) })

        for entry in snapshot where entry.pid != ownPID && entry.layer == 0 && entry.alpha > 0 {
            guard tracker.borders[entry.window] == nil else { continue }
            let before = previous[entry.window]
            guard before == nil || before!.alpha <= 0 || before!.tracked else { continue }
            let space = SweaterWindowServer.space(
                of: entry.window, connection: SweaterWindowServer.mainConnection)
            observed[entry.window]?.justCreated = tracker.create(
                window: entry.window, space: space)
        }

        for (window, border) in tracker.borders {
            let source = observed[window]
            let overlay = observed[border.overlayIdentifier]
            if source?.justCreated == true { continue }

            guard let source, source.alpha > 0 else {
                border.missingOverlaySnapshots = 0
                if border.visible || (overlay?.alpha ?? 0) > 0 { tracker.hide(window: window) }
                border.missingSnapshots += 1
                if border.missingSnapshots >= 10 {
                    border.missingSnapshots = 0
                    if !windowExists(window) { _ = tracker.destroy(window: window, space: 0) }
                }
                continue
            }
            border.missingSnapshots = 0

            if now >= border.spaceCheckAfter {
                border.spaceCheckAfter = now + 0.20
                border.refreshSpace()
            }

            if !border.resizeSuppressed,
                border.suppressLiveResize(bounds: source.bounds, settings: settings)
            {
                continue
            }

            guard
                let geometry = SweaterWindowServer.bounds(
                    of: window, connection: border.connection)
            else { continue }

            if border.resizeSuppressed,
                abs(source.bounds.width - geometry.width) > 1
                    || abs(source.bounds.height - geometry.height) > 1
                    || border.suppressLiveResize(bounds: geometry, settings: settings)
            {
                continue
            }

            let scaled =
                geometry.width > 0 && geometry.height > 0
                && abs(source.bounds.width / geometry.width - 1) > 0.08
                && abs(source.bounds.height / geometry.height - 1) > 0.08
            let settled =
                abs(source.bounds.width - geometry.width) <= 1
                && abs(source.bounds.height - geometry.height) <= 1
            border.nativeTransform = scaled || (border.nativeTransform && !settled)
            if border.nativeTransform {
                if border.visible { tracker.hide(window: window) }
                continue
            }

            if overlay == nil || overlay!.alpha <= 0 {
                border.missingOverlaySnapshots += 1
                if border.missingOverlaySnapshots >= 3, now >= border.overlayRebuildAfter {
                    border.resetSurface()
                    border.missingOverlaySnapshots = 0
                    border.overlayRebuildAfter = now + 1
                    border.spaceCheckAfter = 0
                }
            } else {
                border.missingOverlaySnapshots = 0
            }

            if !border.visible || overlay == nil || overlay!.alpha <= 0 {
                border.metadataDirty = true
                border.updateGeometry(
                    settings: settings, bounds: geometry, opacity: source.alpha)
            } else if geometry != border.targetBounds || abs(source.alpha - border.opacity) > 0.001
                || !border.geometryValid || border.needsRedraw || border.metadataDirty
            {
                border.updateGeometry(
                    settings: settings, bounds: geometry, opacity: source.alpha)
            } else if let overlay {
                let placed =
                    settings.order == SweaterOrdering.below
                    ? overlay.rank > source.rank && overlay.rank < source.nextForeign
                    : overlay.rank < source.rank && overlay.rank > source.previousForeign
                if !placed { border.reorder(settings: settings) }
            }
        }

        for key in observed.keys {
            observed[key]?.tracked = tracker.borders[key] != nil
        }
        previous = observed
        return moved
    }
}
